mod channel;
mod error;
mod macros;
mod shutdown;
mod signal_trait;
mod traits;

mod interface;
#[cfg(not(target_family = "wasm"))]
mod interface_os;
#[cfg(target_family = "wasm")]
mod interface_web;

pub use channel::{SignalReceiver, SignalSender, signal_channel};
pub use error::AppError;
pub use interface::{DartSignalPack, send_rust_signal, start_rust_logic};
pub use shutdown::dart_shutdown;
pub use signal_trait::{
  DartSignal, DartSignalBinary, RustSignal, RustSignalBinary, SignalPiece,
};

pub use rinf_proc::{
  DartSignal, DartSignalBinary, RustSignal, RustSignalBinary, SignalPiece,
};

#[doc(hidden)]
pub use bincode::{deserialize, serialize};
