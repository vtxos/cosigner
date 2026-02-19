use core::fmt;

#[derive(Debug, Clone)]
pub enum Error {
    InvalidZeroScalar,
    InvalidScalar,
    InvalidPoint,
    InvalidSignature,
    IdentityCommitment,
    UnknownIdentifier,
    IncorrectNumberOfCommitments,
    IncorrectBindingFactorPreimages,
    MismatchedCommitment,
    SerializationError,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidZeroScalar => write!(f, "invalid zero scalar"),
            Error::InvalidScalar => write!(f, "invalid scalar"),
            Error::InvalidPoint => write!(f, "invalid point"),
            Error::InvalidSignature => write!(f, "invalid signature"),
            Error::IdentityCommitment => write!(f, "identity commitment"),
            Error::UnknownIdentifier => write!(f, "unknown identifier"),
            Error::IncorrectNumberOfCommitments => {
                write!(f, "incorrect number of commitments")
            }
            Error::IncorrectBindingFactorPreimages => {
                write!(f, "incorrect binding factor preimages")
            }
            Error::MismatchedCommitment => write!(f, "mismatched commitment"),
            Error::SerializationError => write!(f, "serialization error"),
        }
    }
}
