//! Byte-exact vectors from the v1 TypeScript link: the same suite, keys, hellos,
//! fragments and pairing link give the same bytes here, so v2 inherits v1's crypto.

use serde_json::Value;

use crate::frag::Fragmenter;
use crate::keys::{Identity, device_id_for, generate_key_pair, identity_fingerprint};
use crate::noise::{Handshake, prologue_for};
use crate::pairing::{HandshakeHello, PairingOffer, pairing_uri};

fn vectors() -> Value {
    serde_json::from_str(include_str!("../tests/fixtures/v1_vectors.json")).unwrap()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&text[at..at + 2], 16).unwrap())
        .collect()
}

fn fill(start: usize) -> [u8; 32] {
    std::array::from_fn(|i| ((start + i * 7) & 0xff) as u8)
}

/// The first 32 bytes the vector's deterministic random source gave: the ephemeral key.
fn ephemeral(seed: usize) -> [u8; 32] {
    std::array::from_fn(|i| ((seed + i * 13) & 0xff) as u8)
}

fn identity(v: &Value, who: &str) -> Identity {
    let keys = &v["keys"][who];
    Identity::new(
        keys["publicKey"].as_str().unwrap(),
        keys["privateKey"].as_str().unwrap(),
    )
    .unwrap()
}

#[test]
fn keys_match() {
    let v = vectors();
    for (who, start) in [("phone", 1), ("host", 100)] {
        let pair = generate_key_pair(Some(&fill(start))).unwrap();
        let keys = &v["keys"][who];
        assert_eq!(pair.public_key, keys["publicKey"].as_str().unwrap());
        assert_eq!(pair.private_key, keys["privateKey"].as_str().unwrap());
        assert_eq!(
            device_id_for(&pair.public_key).unwrap(),
            keys["deviceId"].as_str().unwrap()
        );
        assert_eq!(
            identity_fingerprint(&pair.public_key).unwrap(),
            keys["fingerprint"].as_str().unwrap()
        );
    }
}

#[test]
fn handshake_and_transport_match() {
    let v = vectors();
    let (phone, host) = (identity(&v, "phone"), identity(&v, "host"));
    let prologue = prologue_for(
        1,
        "connection",
        v["connectionId"].as_str().unwrap(),
        &host.device_id,
        &phone.device_id,
    )
    .unwrap();
    assert_eq!(hex(&prologue), v["prologue"].as_str().unwrap());

    let hs = &v["handshake"];
    let hello = HandshakeHello {
        name: Some("Pixel 9 Pro".into()),
        pairing_code: Some("Qk3x_9-AbCdEfGhIjKlMnOpQ".into()),
    };
    assert_eq!(
        hex(&hello.encode().unwrap()),
        hs["phoneHello"].as_str().unwrap()
    );

    let mut initiator = Handshake::build(
        true,
        &phone,
        host.public_bytes(),
        &prologue,
        Some(&ephemeral(9)),
    )
    .unwrap();
    let mut responder = Handshake::build(
        false,
        &host,
        phone.public_bytes(),
        &prologue,
        Some(&ephemeral(77)),
    )
    .unwrap();
    let msg1 = initiator.write(&hello.encode().unwrap()).unwrap();
    assert_eq!(hex(&msg1), hs["msg1"].as_str().unwrap());
    assert_eq!(
        hex(&responder.read(&msg1).unwrap()),
        hs["readByHost"].as_str().unwrap()
    );
    let host_hello = HandshakeHello {
        name: Some("Desk".into()),
        pairing_code: None,
    };
    let msg2 = responder.write(&host_hello.encode().unwrap()).unwrap();
    assert_eq!(hex(&msg2), hs["msg2"].as_str().unwrap());
    assert_eq!(
        hex(&initiator.read(&msg2).unwrap()),
        hs["readByPhone"].as_str().unwrap()
    );

    // v1 counted nonces from 0 in send order; here the nonce is given, so pass the same numbers.
    let (to_host, to_phone) = (initiator.finish().unwrap(), responder.finish().unwrap());
    let fragments: Vec<Vec<u8>> = v["fragments"]["frames"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| unhex(f.as_str().unwrap()))
        .collect();
    for (nonce, step) in v["transport"]["toHost"]
        .as_array()
        .unwrap()
        .iter()
        .enumerate()
    {
        let plain = match step["plain"].as_str().unwrap() {
            text if text.starts_with("fragment:") => {
                fragments[text[9..].parse::<usize>().unwrap()].clone()
            }
            text => unhex(text),
        };
        assert_eq!(
            hex(&to_host.encrypt(nonce as u64, &plain).unwrap()),
            step["cipher"].as_str().unwrap()
        );
    }
    for (nonce, step) in v["transport"]["toPhone"]
        .as_array()
        .unwrap()
        .iter()
        .enumerate()
    {
        let cipher = unhex(step["cipher"].as_str().unwrap());
        assert_eq!(
            hex(&to_host.decrypt(nonce as u64, &cipher).unwrap()),
            step["plain"].as_str().unwrap()
        );
        assert_eq!(
            hex(&to_phone
                .encrypt(nonce as u64, &unhex(step["plain"].as_str().unwrap()))
                .unwrap()),
            hex(&cipher)
        );
    }
}

#[test]
fn fragments_and_pairing_uri_match() {
    let v = vectors();
    let big: Vec<u8> = (0..v["fragments"]["length"].as_u64().unwrap() as usize)
        .map(|i| ((i * 37 + 11) & 0xff) as u8)
        .collect();
    let frames: Vec<String> = Fragmenter::default()
        .split(&big)
        .unwrap()
        .iter()
        .map(|f| hex(f))
        .collect();
    let want: Vec<&str> = v["fragments"]["frames"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f.as_str().unwrap())
        .collect();
    assert_eq!(frames, want);

    let offer: PairingOffer = serde_json::from_value(v["pairing"]["offer"].clone()).unwrap();
    assert_eq!(pairing_uri(&offer), v["pairing"]["uri"].as_str().unwrap());
}
