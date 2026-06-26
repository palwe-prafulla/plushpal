use std::{env, fs, io, path::Path};

fn collect_files(root: &Path, directory: &Path, output: &mut Vec<String>) -> io::Result<()> {
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        if path.is_dir() {
            collect_files(root, &path, output)?;
        } else if path.is_file() {
            let relative = path
                .strip_prefix(root)
                .expect("asset must remain under asset root")
                .to_string_lossy()
                .replace('\\', "/");
            if !relative.starts_with('.') {
                output.push(relative);
            }
        }
    }
    Ok(())
}

fn main() -> io::Result<()> {
    let manifest = env::var("CARGO_MANIFEST_DIR").expect("manifest directory is available");
    let root = Path::new(&manifest).join("assets/flutter_web");
    let mut assets = Vec::new();
    collect_files(&root, &root, &mut assets)?;
    assets.sort();

    let mut generated = String::from(
        "fn embedded_flutter_asset(path: &str) -> Option<&'static [u8]> {\n    match path {\n",
    );
    for asset in assets {
        let absolute = root.join(&asset);
        generated.push_str(&format!(
            "        {asset:?} => Some(include_bytes!({absolute:?})),\n",
            absolute = absolute.to_string_lossy()
        ));
    }
    generated.push_str("        _ => None,\n    }\n}\n");

    let out = env::var("OUT_DIR").expect("output directory is available");
    fs::write(Path::new(&out).join("flutter_assets.rs"), generated)?;
    println!("cargo:rerun-if-changed={}", root.display());
    Ok(())
}
