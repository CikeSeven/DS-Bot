//! The reliable channel of one link: every frame has a seq, the peer acks the
//! highest seq it has in order, and whatever is not acked is sent again after a
//! reconnect. The cipher nonce is the seq, so a frame sent again is byte for byte
//! the frame sent before.

use std::collections::VecDeque;

use crate::error::LinkError;
use crate::frag::{Fragmenter, Reassembler};
use crate::noise::Cipher;
use crate::wire::{Binary, LinkId, encode_ack, encode_data};

/// Bytes sent and not yet acked, per link.
pub const WINDOW_BYTES: usize = 512 * 1024;
pub const HOST_CAP_BYTES: usize = 8 * 1024 * 1024;
pub const CLIENT_CAP_BYTES: usize = 4 * 1024 * 1024;
const ACK_AFTER_FRAMES: u32 = 16;
const ACK_AFTER_BYTES: usize = 128 * 1024;
const ACK_DELAY_MS: u64 = 200;
const RTO_MIN_MS: u64 = 5_000;
const RTO_MAX_MS: u64 = 60_000;

/// Keeps one socket under the Relay Server's per-second limits (512 frames, 8 MiB).
#[derive(Debug)]
pub struct Pacer {
    bytes: f64,
    frames: f64,
    at: u64,
}

const PACE_BYTES_PER_SEC: f64 = 6.0 * 1024.0 * 1024.0;
const PACE_BURST_BYTES: f64 = 1024.0 * 1024.0;
const PACE_FRAMES_PER_SEC: f64 = 400.0;
const PACE_BURST_FRAMES: f64 = 64.0;

impl Pacer {
    pub fn new(now: u64) -> Self {
        Self {
            bytes: PACE_BURST_BYTES,
            frames: PACE_BURST_FRAMES,
            at: now,
        }
    }

    fn refill(&mut self, now: u64) {
        let elapsed = now.saturating_sub(self.at) as f64 / 1000.0;
        self.at = self.at.max(now);
        self.bytes = (self.bytes + elapsed * PACE_BYTES_PER_SEC).min(PACE_BURST_BYTES);
        self.frames = (self.frames + elapsed * PACE_FRAMES_PER_SEC).min(PACE_BURST_FRAMES);
    }

    /// Takes the budget for one frame, if there is some.
    pub fn take(&mut self, bytes: usize, now: u64) -> bool {
        self.refill(now);
        if self.frames < 1.0 || self.bytes < bytes.min(PACE_BURST_BYTES as usize) as f64 {
            return false;
        }
        self.frames -= 1.0;
        self.bytes -= bytes as f64;
        true
    }

    /// When a frame of this size fits again.
    pub fn ready_at(&self, bytes: usize) -> u64 {
        let need_bytes = (bytes.min(PACE_BURST_BYTES as usize) as f64 - self.bytes).max(0.0)
            / PACE_BYTES_PER_SEC;
        let need_frames = (1.0 - self.frames).max(0.0) / PACE_FRAMES_PER_SEC;
        self.at + (need_bytes.max(need_frames) * 1000.0).ceil() as u64 + 1
    }
}

#[derive(Debug)]
struct Outgoing {
    seq: u64,
    ciphertext: Vec<u8>,
    sent_at: Option<u64>,
    resent: bool,
}

pub struct Channel {
    link: LinkId,
    cipher: Cipher,
    fragmenter: Fragmenter,
    reassembler: Reassembler,
    cap_bytes: usize,
    queue: VecDeque<Outgoing>,
    queued_bytes: usize,
    next_seq: u64,
    acked: u64,
    sent_upto: u64,
    open: bool,
    srtt: Option<f64>,
    rto_ms: u64,
    rto_at: Option<u64>,
    recv: u64,
    owed_frames: u32,
    owed_bytes: usize,
    owed_since: Option<u64>,
    ack_now: bool,
}

impl Channel {
    pub fn new(link: LinkId, cipher: Cipher, cap_bytes: usize) -> Self {
        Self {
            link,
            cipher,
            fragmenter: Fragmenter::default(),
            reassembler: Reassembler::default(),
            cap_bytes,
            queue: VecDeque::new(),
            queued_bytes: 0,
            next_seq: 1,
            acked: 0,
            sent_upto: 0,
            open: false,
            srtt: None,
            rto_ms: RTO_MIN_MS,
            rto_at: None,
            recv: 0,
            owed_frames: 0,
            owed_bytes: 0,
            owed_since: None,
            ack_now: false,
        }
    }

    pub fn link(&self) -> LinkId {
        self.link
    }

    /// Bytes waiting for the peer's ack, sent or not.
    pub fn buffered_bytes(&self) -> usize {
        self.queued_bytes
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    /// Queues one message. Fails with `OVERFLOW` when the buffer would pass its cap.
    pub fn send(&mut self, message: &[u8]) -> Result<(), LinkError> {
        if self.queued_bytes + message.len() > self.cap_bytes {
            return Err(LinkError::new("OVERFLOW", "The peer is too far behind."));
        }
        for piece in self.fragmenter.split(message)? {
            let ciphertext = self.cipher.encrypt(self.next_seq, &piece)?;
            self.queued_bytes += ciphertext.len();
            self.queue.push_back(Outgoing {
                seq: self.next_seq,
                ciphertext,
                sent_at: None,
                resent: false,
            });
            self.next_seq += 1;
        }
        Ok(())
    }

    /// Frames flow only while this side's socket is attached and the peer is present.
    /// Opening starts a new round: everything not acked goes again, and this side's
    /// ack goes first so the peer can do the same.
    pub fn set_open(&mut self, open: bool) {
        if open && !self.open {
            self.sent_upto = self.acked;
            self.rto_ms = RTO_MIN_MS;
            self.ack_now = true;
            for frame in &mut self.queue {
                if frame.sent_at.is_some() {
                    frame.resent = true;
                }
            }
        }
        if !open {
            self.rto_at = None;
        }
        self.open = open;
    }

    /// Reads one frame of this link. Returns the messages it completed, in order.
    pub fn receive(&mut self, frame: Binary<'_>, now: u64) -> Result<Vec<Vec<u8>>, LinkError> {
        match frame {
            Binary::Ack { ack, .. } => {
                self.on_ack(ack, now)?;
                Ok(Vec::new())
            }
            Binary::Data {
                seq,
                ack,
                ciphertext,
                ..
            } => {
                self.on_ack(ack, now)?;
                if seq != self.recv + 1 {
                    // A frame sent again, or one after a gap: the peer hears our ack
                    // and sends again from there.
                    self.ack_now = true;
                    return Ok(Vec::new());
                }
                let plaintext = self.cipher.decrypt(seq, ciphertext)?;
                self.recv = seq;
                self.owed_frames += 1;
                self.owed_bytes += ciphertext.len();
                self.owed_since.get_or_insert(now);
                Ok(self.reassembler.join(plaintext)?.into_iter().collect())
            }
        }
    }

    fn on_ack(&mut self, ack: u64, now: u64) -> Result<(), LinkError> {
        if ack >= self.next_seq {
            return Err(LinkError::invalid(
                "The peer acked a frame that was never sent.",
            ));
        }
        if ack <= self.acked {
            return Ok(());
        }
        let mut sample = None;
        while self.queue.front().is_some_and(|frame| frame.seq <= ack) {
            let frame = self.queue.pop_front().expect("present");
            self.queued_bytes -= frame.ciphertext.len();
            if let (Some(sent), false) = (frame.sent_at, frame.resent) {
                sample = Some(now.saturating_sub(sent) as f64);
            }
        }
        if let Some(sample) = sample {
            let srtt = self
                .srtt
                .map_or(sample, |srtt| srtt * 0.875 + sample * 0.125);
            self.srtt = Some(srtt);
        }
        self.acked = ack;
        self.sent_upto = self.sent_upto.max(ack);
        self.rto_ms = self.base_rto();
        self.rto_at = (self.sent_upto > self.acked).then(|| now + self.rto_ms);
        Ok(())
    }

    fn base_rto(&self) -> u64 {
        self.srtt.map_or(RTO_MIN_MS, |srtt| {
            ((srtt * 4.0) as u64).clamp(RTO_MIN_MS, RTO_MAX_MS)
        })
    }

    /// Goes back to the first unacked frame when acks stop coming.
    pub fn tick(&mut self, now: u64) {
        if self.rto_at.is_some_and(|at| now >= at) && self.sent_upto > self.acked {
            self.sent_upto = self.acked;
            self.rto_ms = (self.rto_ms * 2).min(RTO_MAX_MS);
            self.rto_at = None;
            for frame in &mut self.queue {
                if frame.sent_at.is_some() {
                    frame.resent = true;
                }
            }
        }
    }

    fn in_flight_bytes(&self) -> usize {
        self.queue
            .iter()
            .take_while(|frame| frame.seq <= self.sent_upto)
            .map(|frame| frame.ciphertext.len())
            .sum()
    }

    /// The frames to write now: data inside the window and the pacer's budget, and an
    /// ack when one is due and no data frame carries it.
    pub fn poll(&mut self, pacer: &mut Pacer, now: u64) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        if !self.open {
            return out;
        }
        let mut in_flight = self.in_flight_bytes();
        while let Some(frame) = self
            .queue
            .iter_mut()
            .find(|frame| frame.seq == self.sent_upto + 1)
        {
            let size = frame.ciphertext.len();
            if in_flight > 0 && in_flight + size > WINDOW_BYTES {
                break;
            }
            if !pacer.take(size, now) {
                break;
            }
            frame.sent_at = Some(now);
            out.push(encode_data(
                self.link,
                frame.seq,
                self.recv,
                &frame.ciphertext,
            ));
            self.sent_upto = frame.seq;
            in_flight += size;
        }
        if !out.is_empty() {
            self.clear_owed();
            if self.rto_at.is_none() {
                self.rto_at = Some(now + self.rto_ms);
            }
        } else if self.ack_due(now) && pacer.take(crate::wire::ACK_FRAME_BYTES, now) {
            out.push(encode_ack(self.link, self.recv));
            self.clear_owed();
        }
        out
    }

    fn ack_due(&self, now: u64) -> bool {
        self.ack_now
            || self.owed_frames >= ACK_AFTER_FRAMES
            || self.owed_bytes >= ACK_AFTER_BYTES
            || self
                .owed_since
                .is_some_and(|since| now >= since + ACK_DELAY_MS)
    }

    fn clear_owed(&mut self) {
        self.owed_frames = 0;
        self.owed_bytes = 0;
        self.owed_since = None;
        self.ack_now = false;
    }

    /// The earliest time `tick` or `poll` has work, the pacer aside.
    pub fn next_deadline(&self) -> Option<u64> {
        if !self.open {
            return None;
        }
        let ack = if self.ack_now {
            None
        } else {
            self.owed_since.map(|since| since + ACK_DELAY_MS)
        };
        [self.rto_at.filter(|_| self.sent_upto > self.acked), ack]
            .into_iter()
            .flatten()
            .min()
    }

    /// When the pacer lets the next frame go, if only the pacer holds it back. Call it
    /// after `poll`: a frame the window holds back waits for the peer's ack instead, and
    /// its pacer time may be long past.
    pub fn paced_until(&self, pacer: &Pacer) -> Option<u64> {
        if !self.open {
            return None;
        }
        let in_flight = self.in_flight_bytes();
        match self
            .queue
            .iter()
            .find(|frame| frame.seq == self.sent_upto + 1)
        {
            Some(frame) if in_flight == 0 || in_flight + frame.ciphertext.len() <= WINDOW_BYTES => {
                Some(pacer.ready_at(frame.ciphertext.len()))
            }
            Some(_) => None,
            None => (self.ack_now
                || self.owed_frames >= ACK_AFTER_FRAMES
                || self.owed_bytes >= ACK_AFTER_BYTES)
                .then(|| pacer.ready_at(crate::wire::ACK_FRAME_BYTES)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::{Identity, generate_key_pair};
    use crate::noise::{Handshake, prologue};

    fn identity() -> Identity {
        let pair = generate_key_pair(None).unwrap();
        Identity::new(&pair.public_key, &pair.private_key).unwrap()
    }

    fn pair() -> (Channel, Channel) {
        let (phone, host) = (identity(), identity());
        let link = LinkId::random();
        let prologue = prologue(&link.text(), &host.device_id, &phone.device_id).unwrap();
        let mut a = Handshake::initiator(&phone, host.public_bytes(), &prologue).unwrap();
        let mut b = Handshake::responder(&host, phone.public_bytes(), &prologue).unwrap();
        b.read(&a.write(b"").unwrap()).unwrap();
        a.read(&b.write(b"").unwrap()).unwrap();
        (
            Channel::new(link, a.finish().unwrap(), CLIENT_CAP_BYTES),
            Channel::new(link, b.finish().unwrap(), HOST_CAP_BYTES),
        )
    }

    fn deliver(from: &mut Channel, to: &mut Channel, pacer: &mut Pacer, now: u64) -> Vec<Vec<u8>> {
        let mut got = Vec::new();
        for frame in from.poll(pacer, now) {
            got.extend(to.receive(Binary::decode(&frame).unwrap(), now).unwrap());
        }
        got
    }

    #[test]
    fn delivers_in_order_and_resends_after_a_drop() {
        let (mut phone, mut host) = pair();
        let mut pacer = Pacer::new(0);
        phone.set_open(true);
        host.set_open(true);
        phone.send(b"one").unwrap();
        phone.send(b"two").unwrap();
        // The first round is lost with the socket.
        let lost = phone.poll(&mut pacer, 0);
        assert_eq!(lost.len(), 2);
        phone.set_open(false);
        phone.send(b"three").unwrap();
        assert!(phone.poll(&mut pacer, 1).is_empty());
        phone.set_open(true);
        assert_eq!(
            deliver(&mut phone, &mut host, &mut pacer, 2),
            vec![b"one".to_vec(), b"two".to_vec(), b"three".to_vec()]
        );
        // A late copy of the lost frames is dropped as a duplicate.
        for frame in lost {
            assert!(
                host.receive(Binary::decode(&frame).unwrap(), 3)
                    .unwrap()
                    .is_empty()
            );
        }
        assert_eq!(phone.buffered_bytes(), 3 * 16 + 11);
        // The host owes an ack now; it frees the phone's buffer.
        deliver(&mut host, &mut phone, &mut pacer, 4);
        assert_eq!(phone.buffered_bytes(), 0);
    }

    #[test]
    fn a_gap_is_not_fatal() {
        let (mut phone, mut host) = pair();
        let mut pacer = Pacer::new(0);
        phone.set_open(true);
        host.set_open(true);
        for word in [b"a", b"b", b"c"] {
            phone.send(word).unwrap();
        }
        let frames = phone.poll(&mut pacer, 0);
        assert!(
            host.receive(Binary::decode(&frames[1]).unwrap(), 0)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            host.receive(Binary::decode(&frames[0]).unwrap(), 0)
                .unwrap(),
            vec![b"a".to_vec()]
        );
        // No ack has moved, so after the timeout the phone sends from the first frame again.
        phone.tick(RTO_MIN_MS + 1);
        assert_eq!(
            deliver(&mut phone, &mut host, &mut pacer, RTO_MIN_MS + 2),
            vec![b"b".to_vec(), b"c".to_vec()]
        );
    }

    #[test]
    fn large_messages_and_window_and_cap() {
        let (mut phone, mut host) = pair();
        let mut pacer = Pacer::new(0);
        phone.set_open(true);
        host.set_open(true);
        let big = vec![7u8; 1_500_000];
        host.send(&big).unwrap();
        let mut now = 0;
        let mut got = Vec::new();
        for _ in 0..200 {
            now += 50;
            got.extend(deliver(&mut host, &mut phone, &mut pacer, now));
            deliver(&mut phone, &mut host, &mut pacer, now + ACK_DELAY_MS);
            if !got.is_empty() {
                break;
            }
        }
        assert_eq!(got, vec![big]);
        assert!(host.send(&vec![0; HOST_CAP_BYTES + 1]).is_err());
        assert_eq!(
            host.send(&vec![0; HOST_CAP_BYTES + 1]).unwrap_err().code,
            "OVERFLOW"
        );
    }

    #[test]
    fn an_ack_beyond_what_was_sent_is_invalid() {
        let (mut phone, _) = pair();
        assert!(
            phone
                .receive(
                    Binary::Ack {
                        link: phone.link(),
                        ack: 1
                    },
                    0
                )
                .is_err()
        );
    }

    #[test]
    fn pacer_spaces_out_a_burst() {
        let mut pacer = Pacer::new(0);
        let mut sent = 0;
        while pacer.take(48 * 1024, 0) {
            sent += 1;
        }
        assert_eq!(sent, 21);
        let at = pacer.ready_at(48 * 1024);
        assert!(at > 0 && at < 20);
        assert!(pacer.take(48 * 1024, at));
    }
}
