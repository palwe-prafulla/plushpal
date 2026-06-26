#[cfg(feature = "native-runtime")]
use std::{path::PathBuf, sync::Arc};

#[cfg(feature = "native-runtime")]
use plushpal_core_domain::AgeBand;
#[cfg(feature = "native-runtime")]
use plushpal_desktop_host::{
    native_runtime::{NativeConversationEngine, NativeModelInstaller},
    ConversationEngine, LocalTurnCommand,
};
#[cfg(feature = "native-runtime")]
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .ok_or("usage: model_smoke <verified-model.gguf>")?
        .canonicalize()?;
    NativeModelInstaller::verify_model_path(&path)
        .map_err(|error| format!("model verification failed: {error:?}"))?;
    let engine: Arc<dyn ConversationEngine> = Arc::new(
        NativeConversationEngine::load(&path)
            .map_err(|error| format!("model activation failed: {error:?}"))?,
    );
    let response_engine = Arc::clone(&engine);
    let response = tokio::task::spawn_blocking(move || {
        response_engine.generate_local(LocalTurnCommand {
            age_band: AgeBand::SixToEight,
            character_alias: "Teddy".to_owned(),
            text: "Why is the sky blue? Please answer in two short sentences.".to_owned(),
            parent_guidance: None,
        })
    })
    .await?
    .map_err(|error| format!("generation failed: {error:?}"))?;
    println!("speech: {}", response.speech);
    println!("suggest_trusted_adult: {}", response.suggest_trusted_adult);
    let cancellation_engine = Arc::clone(&engine);
    let generation = tokio::task::spawn_blocking(move || {
        cancellation_engine.generate_local(LocalTurnCommand {
            age_band: AgeBand::NineToTwelve,
            character_alias: "Teddy".to_owned(),
            text: "Tell me a very long story with as much detail as possible.".to_owned(),
            parent_guidance: None,
        })
    });
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    engine
        .cancel()
        .map_err(|error| format!("cancellation request failed: {error:?}"))?;
    if generation.await?.is_ok() {
        return Err("generation unexpectedly completed after cancellation".into());
    }
    println!("cancellation: passed");
    Ok(())
}

#[cfg(not(feature = "native-runtime"))]
fn main() {
    eprintln!("model_smoke requires --features native-runtime");
    std::process::exit(2);
}
