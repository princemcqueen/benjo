use mlua::{chunk::Compiler, Lua};
use std::{env, fs, path::Path, process::exit};

fn walk(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, out);
            } else if let Some(ext) = p.extension() {
                if ext == "luau" || ext == "lua" {
                    out.push(p);
                }
            }
        }
    }
}

fn main() {
    let root = env::args().nth(1).expect("usage: luaucheck <dir>");
    let mut files = Vec::new();
    walk(Path::new(&root), &mut files);
    files.sort();
    let lua = Lua::new();
    lua.set_compiler(Compiler::new().set_optimization_level(1).set_debug_level(1));
    let mut bad = 0;
    for f in &files {
        let src = match fs::read_to_string(f) {
            Ok(s) => s,
            Err(e) => {
                println!("READ ERROR {}: {}", f.display(), e);
                bad += 1;
                continue;
            }
        };
        let name = format!("={}", f.strip_prefix(&root).unwrap_or(f).display());
        match lua.load(&src).set_name(&name).into_function() {
            Ok(_) => {}
            Err(e) => {
                println!("SYNTAX ERROR {}\n    {}", f.display(), e.to_string().replace('\n', "\n    "));
                bad += 1;
            }
        }
    }
    println!("checked {} files, {} with errors", files.len(), bad);
    exit(if bad > 0 { 1 } else { 0 });
}
