// Polyfill browser APIs that @actual-app/api expects in Node.js
if (typeof globalThis.navigator === "undefined") {
  globalThis.navigator = {
    platform: process.platform,
    userAgent: "node",
    language: "en",
    languages: ["en"],
  };
}
