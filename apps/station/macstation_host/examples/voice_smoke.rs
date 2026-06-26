#[cfg(feature = "native-runtime")]
use std::path::PathBuf;

#[cfg(feature = "native-runtime")]
use plushpal_desktop_host::{native_runtime::PocketVoiceEngine, VoiceEngine};

#[cfg(feature = "native-runtime")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let model_directory = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .ok_or("usage: voice_smoke <pocket-tts-model-directory> <reference.wav> <output.wav>")?;
    let reference = std::env::args_os()
        .nth(2)
        .map(PathBuf::from)
        .ok_or("missing reference WAV")?;
    let output = std::env::args_os()
        .nth(3)
        .map(PathBuf::from)
        .ok_or("missing output WAV")?;
    let temporary = std::env::temp_dir().join("plushpal-voice-smoke");
    let engine = PocketVoiceEngine::load(&model_directory, &temporary)
        .map_err(|error| format!("voice model activation failed: {error:?}"))?;
    let reference = std::fs::read(reference)?;
    let wav = engine
        .synthesize(
            &reference,
            "Hello! I am ready to explore, learn, and play together.",
        )
        .map_err(|error| format!("voice synthesis failed: {error:?}"))?;
    std::fs::write(&output, &wav)?;
    println!("voice_wav_bytes: {}", wav.len());
    println!("output: {}", output.display());
    Ok(())
}

#[cfg(not(feature = "native-runtime"))]
fn main() {
    eprintln!("voice_smoke requires --features native-runtime");
    std::process::exit(2);
}
