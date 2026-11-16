//! Splits a message before encryption and joins it after decryption, in the v1
//! `DSBF` layout: "DSBF", version 1, message id u32, index u16, total u16 and the
//! message length u32, all big endian, then the chunk.

use std::collections::HashMap;

use crate::error::LinkError;

pub const CHUNK_BYTES: usize = 48 * 1024;
pub const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
const MAGIC: &[u8; 4] = b"DSBF";
const VERSION: u8 = 1;
const HEADER_BYTES: usize = 17;
const MAX_ASSEMBLIES: usize = 8;

#[derive(Debug)]
pub struct Fragmenter {
    next_id: u32,
}

impl Default for Fragmenter {
    fn default() -> Self {
        Self { next_id: 1 }
    }
}

impl Fragmenter {
    pub fn split(&mut self, message: &[u8]) -> Result<Vec<Vec<u8>>, LinkError> {
        if message.len() > MAX_MESSAGE_BYTES {
            return Err(LinkError::new(
                "MESSAGE_TOO_LARGE",
                "A message is larger than 4 MiB.",
            ));
        }
        if message.len() <= CHUNK_BYTES {
            return Ok(vec![message.to_vec()]);
        }
        let id = self.next_id;
        self.next_id = if id == u32::MAX { 1 } else { id + 1 };
        let total = message.len().div_ceil(CHUNK_BYTES);
        Ok(message
            .chunks(CHUNK_BYTES)
            .enumerate()
            .map(|(index, chunk)| {
                let mut frame = Vec::with_capacity(HEADER_BYTES + chunk.len());
                frame.extend_from_slice(MAGIC);
                frame.push(VERSION);
                frame.extend_from_slice(&id.to_be_bytes());
                frame.extend_from_slice(&(index as u16).to_be_bytes());
                frame.extend_from_slice(&(total as u16).to_be_bytes());
                frame.extend_from_slice(&(message.len() as u32).to_be_bytes());
                frame.extend_from_slice(chunk);
                frame
            })
            .collect())
    }
}

#[derive(Debug)]
struct Assembly {
    total: usize,
    total_bytes: usize,
    data: Vec<u8>,
    received: usize,
}

#[derive(Debug, Default)]
pub struct Reassembler {
    assemblies: HashMap<u32, Assembly>,
}

impl Reassembler {
    /// The whole message once its last piece arrives; a frame without the header is a whole message.
    pub fn join(&mut self, frame: Vec<u8>) -> Result<Option<Vec<u8>>, LinkError> {
        if !frame.starts_with(MAGIC) {
            return Ok(Some(frame));
        }
        let invalid =
            |what: &str| LinkError::invalid(format!("Secure fragment {what} is invalid."));
        if frame.len() < HEADER_BYTES || frame[4] != VERSION {
            return Err(invalid("header"));
        }
        let id = u32::from_be_bytes(frame[5..9].try_into().expect("4 bytes"));
        let index = u16::from_be_bytes(frame[9..11].try_into().expect("2 bytes")) as usize;
        let total = u16::from_be_bytes(frame[11..13].try_into().expect("2 bytes")) as usize;
        let total_bytes = u32::from_be_bytes(frame[13..17].try_into().expect("4 bytes")) as usize;
        if id == 0
            || total < 2
            || index >= total
            || total_bytes <= CHUNK_BYTES
            || total_bytes > MAX_MESSAGE_BYTES
            || total != total_bytes.div_ceil(CHUNK_BYTES)
        {
            return Err(invalid("metadata"));
        }
        let chunk = &frame[HEADER_BYTES..];
        if chunk.len() != CHUNK_BYTES.min(total_bytes - index * CHUNK_BYTES) {
            return Err(invalid("length"));
        }
        if !self.assemblies.contains_key(&id) {
            if index != 0 || self.assemblies.len() >= MAX_ASSEMBLIES {
                return Err(invalid("sequence"));
            }
            self.assemblies.insert(
                id,
                Assembly {
                    total,
                    total_bytes,
                    data: Vec::with_capacity(total_bytes),
                    received: 0,
                },
            );
        }
        let assembly = self.assemblies.get_mut(&id).expect("present");
        if assembly.total != total
            || assembly.total_bytes != total_bytes
            || index != assembly.received
        {
            self.assemblies.remove(&id);
            return Err(invalid("sequence"));
        }
        assembly.data.extend_from_slice(chunk);
        assembly.received += 1;
        if assembly.received < total {
            return Ok(None);
        }
        Ok(self.assemblies.remove(&id).map(|done| done.data))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_and_joins() {
        let big: Vec<u8> = (0..100_000usize)
            .map(|i| ((i * 37 + 11) & 0xff) as u8)
            .collect();
        let mut fragmenter = Fragmenter::default();
        let frames = fragmenter.split(&big).unwrap();
        assert_eq!(frames.len(), 3);
        let mut joiner = Reassembler::default();
        assert_eq!(joiner.join(frames[0].clone()).unwrap(), None);
        assert_eq!(joiner.join(frames[1].clone()).unwrap(), None);
        assert_eq!(joiner.join(frames[2].clone()).unwrap(), Some(big));
        assert_eq!(fragmenter.split(b"small").unwrap(), vec![b"small".to_vec()]);
        assert!(joiner.join(frames[1].clone()).is_err());
    }
}
