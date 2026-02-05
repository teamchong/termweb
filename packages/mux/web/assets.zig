// Web assets embedded at compile time
pub const index_html = @embedFile("index.html");
pub const client_js = @embedFile("client.js");
pub const zstd_wasm = @embedFile("zstd.wasm");
