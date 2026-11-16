//! Base64url without padding, the only text form binary data takes on the link.

use base64::Engine;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};

const ENCODE: GeneralPurpose = base64::engine::general_purpose::URL_SAFE_NO_PAD;
// The TS decoder accepted padding, so this one does too.
const DECODE: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::URL_SAFE,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

pub fn encode(bytes: &[u8]) -> String {
    ENCODE.encode(bytes)
}

pub fn decode(text: &str) -> Option<Vec<u8>> {
    DECODE.decode(text).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_without_padding() {
        assert_eq!(encode(&[0xfb, 0xff]), "-_8");
        assert_eq!(decode("-_8").unwrap(), vec![0xfb, 0xff]);
        assert_eq!(decode("-_8=").unwrap(), vec![0xfb, 0xff]);
        assert!(decode("+/8").is_none());
    }
}
