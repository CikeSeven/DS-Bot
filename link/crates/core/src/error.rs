use std::fmt;

/// An error with a stable code the other side and the app can act on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkError {
    pub code: String,
    pub message: String,
}

impl LinkError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new("INVALID", message)
    }
}

impl fmt::Display for LinkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for LinkError {}
