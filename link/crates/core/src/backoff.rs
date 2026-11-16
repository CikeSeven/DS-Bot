//! Reconnect delays: the first retry at once, then doubling with jitter.

use crate::keys::random_bytes;

const STEPS_MS: [u64; 7] = [0, 250, 500, 1_000, 2_000, 4_000, 8_000];

#[derive(Debug, Clone)]
pub struct Backoff {
    attempt: usize,
    cap_ms: u64,
}

impl Backoff {
    pub fn new(cap_ms: u64) -> Self {
        Self { attempt: 0, cap_ms }
    }

    pub fn reset(&mut self) {
        self.attempt = 0;
    }

    pub fn attempt(&self) -> usize {
        self.attempt
    }

    /// The delay before the next try, ±20 %.
    pub fn next_delay(&mut self) -> u64 {
        let base = STEPS_MS
            .get(self.attempt)
            .copied()
            .unwrap_or(u64::MAX)
            .min(self.cap_ms);
        self.attempt += 1;
        if base == 0 {
            return 0;
        }
        let spread =
            u16::from_be_bytes([random_bytes(1)[0], random_bytes(1)[0]]) as f64 / u16::MAX as f64;
        (base as f64 * (0.8 + spread * 0.4)) as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_up_to_the_cap() {
        let mut backoff = Backoff::new(10_000);
        assert_eq!(backoff.next_delay(), 0);
        let second = backoff.next_delay();
        assert!((200..=300).contains(&second));
        for _ in 0..10 {
            assert!(backoff.next_delay() <= 12_000);
        }
        backoff.reset();
        assert_eq!(backoff.next_delay(), 0);
    }
}
