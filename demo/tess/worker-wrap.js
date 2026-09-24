// The demo host serves only web file types, so the language data is published as eng-traineddata.gz.wasm.
// Point the reader's download of eng.traineddata.gz at that file, then start the normal Tesseract worker.
(function () {
  var f = self.fetch.bind(self);
  self.fetch = function (u, o) { return f(String(u).replace(/eng\.traineddata\.gz(\?.*)?$/, 'eng-traineddata.gz.wasm'), o); };
})();
importScripts('worker.min.js');
