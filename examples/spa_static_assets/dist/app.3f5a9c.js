import init from "/main.7b2e10.wasm";
await WebAssembly.instantiateStreaming(fetch("/main.7b2e10.wasm"));
