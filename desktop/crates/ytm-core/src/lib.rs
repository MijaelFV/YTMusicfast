//! YouTube Music for the Windows and Linux app: the InnerTube API, response parsing and stream
//! resolution. No UI and no playback here, so it builds and tests anywhere.

pub mod api;
pub mod innertube;
pub mod json;
pub mod models;
pub mod parser;
pub mod stream;

pub use api::MusicApi;
pub use innertube::{Credentials, Error, InnerTube};
pub use models::*;
pub use stream::{StreamInfo, StreamResolver};
