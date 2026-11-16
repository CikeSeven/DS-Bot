//! Noise IK between a phone (initiator) and its computer (responder). After the
//! handshake each side encrypts with an explicit nonce, the frame's seq, so a frame
//! can be sent again byte for byte after a reconnect.

use snow::{Builder, HandshakeState, StatelessTransportState};

use crate::error::LinkError;
use crate::keys::{Identity, same_bytes};

pub const NOISE_PATTERN: &str = "Noise_IK_25519_ChaChaPoly_SHA256";
pub const TAG_BYTES: usize = 16;
const MAX_NOISE_MESSAGE: usize = 65_535;

/// Binds the handshake to one link between two known devices.
pub fn prologue(
    link: &str,
    host_device_id: &str,
    client_device_id: &str,
) -> Result<Vec<u8>, LinkError> {
    prologue_for(2, "link", link, host_device_id, client_device_id)
}

pub(crate) fn prologue_for(
    version: u8,
    label: &str,
    id: &str,
    host: &str,
    client: &str,
) -> Result<Vec<u8>, LinkError> {
    for value in [id, host, client] {
        if value.is_empty() || value.contains('\0') {
            return Err(LinkError::invalid(
                "An id is not safe for a Noise prologue.",
            ));
        }
    }
    Ok(
        format!("DS-BOT-LINK\0v={version}\0{label}={id}\0host={host}\0client={client}")
            .into_bytes(),
    )
}

pub struct Handshake {
    state: HandshakeState,
    expected_remote: [u8; 32],
}

impl Handshake {
    pub fn initiator(
        local: &Identity,
        remote_key: [u8; 32],
        prologue: &[u8],
    ) -> Result<Self, LinkError> {
        Self::build(true, local, remote_key, prologue, None)
    }

    pub fn responder(
        local: &Identity,
        expected_remote: [u8; 32],
        prologue: &[u8],
    ) -> Result<Self, LinkError> {
        Self::build(false, local, expected_remote, prologue, None)
    }

    pub(crate) fn build(
        initiator: bool,
        local: &Identity,
        remote_key: [u8; 32],
        prologue: &[u8],
        fixed_ephemeral: Option<&[u8; 32]>,
    ) -> Result<Self, LinkError> {
        let private = local.private_bytes();
        let mut builder = Builder::new(NOISE_PATTERN.parse().expect("valid pattern"))
            .local_private_key(&private)
            .and_then(|builder| builder.prologue(prologue))
            .map_err(noise_error)?;
        if initiator {
            builder = builder
                .remote_public_key(&remote_key)
                .map_err(noise_error)?;
        }
        if let Some(key) = fixed_ephemeral {
            builder = builder.fixed_ephemeral_key_for_testing_only(key);
        }
        let state = if initiator {
            builder.build_initiator()
        } else {
            builder.build_responder()
        }
        .map_err(noise_error)?;
        Ok(Self {
            state,
            expected_remote: remote_key,
        })
    }

    pub fn write(&mut self, payload: &[u8]) -> Result<Vec<u8>, LinkError> {
        let mut out = vec![0; MAX_NOISE_MESSAGE];
        let len = self
            .state
            .write_message(payload, &mut out)
            .map_err(noise_error)?;
        out.truncate(len);
        Ok(out)
    }

    pub fn read(&mut self, message: &[u8]) -> Result<Vec<u8>, LinkError> {
        let mut out = vec![0; message.len()];
        let len = self
            .state
            .read_message(message, &mut out)
            .map_err(noise_error)?;
        let remote = self.state.get_remote_static().unwrap_or_default();
        if !same_bytes(remote, &self.expected_remote) {
            return Err(LinkError::new(
                "PEER_IDENTITY_MISMATCH",
                "The peer key does not match the paired key.",
            ));
        }
        out.truncate(len);
        Ok(out)
    }

    pub fn finish(self) -> Result<Cipher, LinkError> {
        if !self.state.is_handshake_finished() {
            return Err(LinkError::invalid("The Noise handshake is not complete."));
        }
        Ok(Cipher {
            state: self
                .state
                .into_stateless_transport_mode()
                .map_err(noise_error)?,
        })
    }
}

pub struct Cipher {
    state: StatelessTransportState,
}

impl Cipher {
    pub fn encrypt(&self, nonce: u64, plaintext: &[u8]) -> Result<Vec<u8>, LinkError> {
        let mut out = vec![0; plaintext.len() + TAG_BYTES];
        let len = self
            .state
            .write_message(nonce, plaintext, &mut out)
            .map_err(noise_error)?;
        out.truncate(len);
        Ok(out)
    }

    pub fn decrypt(&self, nonce: u64, ciphertext: &[u8]) -> Result<Vec<u8>, LinkError> {
        let mut out = vec![0; ciphertext.len()];
        let len = self
            .state
            .read_message(nonce, ciphertext, &mut out)
            .map_err(|_| LinkError::invalid("A frame did not decrypt."))?;
        out.truncate(len);
        Ok(out)
    }
}

fn noise_error(error: snow::Error) -> LinkError {
    LinkError::new("HANDSHAKE_FAILED", format!("Noise: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::generate_key_pair;

    fn identity() -> Identity {
        let pair = generate_key_pair(None).unwrap();
        Identity::new(&pair.public_key, &pair.private_key).unwrap()
    }

    #[test]
    fn handshake_and_explicit_nonces() {
        let (phone, host) = (identity(), identity());
        let prologue = prologue("bGluaw", &host.device_id, &phone.device_id).unwrap();
        let mut initiator = Handshake::initiator(&phone, host.public_bytes(), &prologue).unwrap();
        let mut responder = Handshake::responder(&host, phone.public_bytes(), &prologue).unwrap();
        let msg1 = initiator.write(b"hi").unwrap();
        assert_eq!(responder.read(&msg1).unwrap(), b"hi");
        let msg2 = responder.write(b"").unwrap();
        assert_eq!(initiator.read(&msg2).unwrap(), b"");
        let (phone_cipher, host_cipher) =
            (initiator.finish().unwrap(), responder.finish().unwrap());
        let sealed = phone_cipher.encrypt(7, b"seven").unwrap();
        assert_eq!(host_cipher.decrypt(7, &sealed).unwrap(), b"seven");
        assert!(host_cipher.decrypt(8, &sealed).is_err());
        // A resend of the same frame is the same bytes.
        assert_eq!(phone_cipher.encrypt(7, b"seven").unwrap(), sealed);
        let back = host_cipher.encrypt(1, b"back").unwrap();
        assert_eq!(phone_cipher.decrypt(1, &back).unwrap(), b"back");
    }

    #[test]
    fn responder_refuses_an_unexpected_phone() {
        let (phone, host, stranger) = (identity(), identity(), identity());
        let prologue = prologue("bGluaw", &host.device_id, &phone.device_id).unwrap();
        let mut initiator =
            Handshake::initiator(&stranger, host.public_bytes(), &prologue).unwrap();
        let mut responder = Handshake::responder(&host, phone.public_bytes(), &prologue).unwrap();
        let msg1 = initiator.write(b"").unwrap();
        assert_eq!(
            responder.read(&msg1).unwrap_err().code,
            "PEER_IDENTITY_MISMATCH"
        );
    }
}
