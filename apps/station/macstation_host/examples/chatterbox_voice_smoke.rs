#[cfg(feature = "native-runtime")]
use std::path::PathBuf;

#[cfg(feature = "native-runtime")]
use plushpal_desktop_host::{native_runtime::ChatterboxVoiceEngine, VoiceEngine};

#[cfg(feature = "native-runtime")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let python = std::env::args_os().nth(1).map(PathBuf::from).ok_or(
        "usage: chatterbox_voice_smoke <python> <script.py> <reference.wav> <output.wav> [engine]",
    )?;
    let script = std::env::args_os()
        .nth(2)
        .map(PathBuf::from)
        .ok_or("missing Chatterbox bridge script")?;
    let reference = std::env::args_os()
        .nth(3)
        .map(PathBuf::from)
        .ok_or("missing reference WAV")?;
    let output = std::env::args_os()
        .nth(4)
        .map(PathBuf::from)
        .ok_or("missing output WAV")?;
    let engine_name = std::env::args()
        .nth(5)
        .unwrap_or_else(|| "standard".to_owned());
    let temporary = std::env::temp_dir().join("plushpal-chatterbox-voice-smoke");
    let engine = ChatterboxVoiceEngine::new(
        python,
        script,
        &temporary,
        engine_name,
        "auto".to_owned(),
        "en".to_owned(),
        "0.68".to_owned(),
        "0.45".to_owned(),
        "0.68".to_owned(),
        "0.05".to_owned(),
        "0.90".to_owned(),
        "1.2".to_owned(),
    )
    .map_err(|error| format!("chatterbox voice activation failed: {error:?}"))?;
    let reference = std::fs::read(reference)?;
    let wav = engine
        .synthesize(&reference, "Woof woof! Hi friend, let us play!")
        .map_err(|error| format!("chatterbox voice synthesis failed: {error:?}"))?;
    std::fs::write(&output, &wav)?;
    println!("voice_wav_bytes: {}", wav.len());
    println!("output: {}", output.display());
    Ok(())
}

#[cfg(not(feature = "native-runtime"))]
fn main() {
    eprintln!("chatterbox_voice_smoke requires --features native-runtime");
    std::process::exit(2);
}
