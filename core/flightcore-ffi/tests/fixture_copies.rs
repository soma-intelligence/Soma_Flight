//! Drift guard: the fixtures replayed by the Swift tests
//! (Packages/FlightCoreFFI/Tests/FlightCoreTests/Fixtures) must be byte-identical
//! copies of core/fixtures/*.json. Rerun core/scripts/build-xcframework.sh to
//! refresh them.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

fn json_files(dir: &Path) -> BTreeSet<String> {
    fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter(|n| n.ends_with(".json"))
        .collect()
}

#[test]
fn package_fixtures_match_core() {
    let core = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let src: PathBuf = core.join("fixtures");
    let copy: PathBuf = core.join("../Packages/FlightCoreFFI/Tests/FlightCoreTests/Fixtures");
    let (a, b) = (json_files(&src), json_files(&copy));
    assert!(!a.is_empty(), "no fixtures in {}", src.display());
    assert_eq!(a, b, "fixture file sets differ; rerun build-xcframework.sh");
    for name in &a {
        assert!(
            fs::read(src.join(name)).unwrap() == fs::read(copy.join(name)).unwrap(),
            "{name} differs from core/fixtures; rerun build-xcframework.sh"
        );
    }
}
