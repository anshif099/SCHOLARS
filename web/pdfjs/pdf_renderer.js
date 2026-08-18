// PDFium WASM can leave its worker initialization promise unresolved on iOS
// WebKit. This same-origin PDF.js renderer returns one page as an image so
// Flutter can keep its drawing and zoom overlays above the document.
(function () {
  const pdfJsBase = new URL('pdfjs/', document.baseURI);
  const pdfJsAssets = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@6.2.108/';
  const documents = new Map();

  const pdfJsReady = import(new URL('pdf.min.mjs', pdfJsBase)).then(
    function (pdfjsLib) {
      pdfjsLib.GlobalWorkerOptions.workerSrc = new URL(
        'pdf.worker.min.mjs',
        pdfJsBase,
      ).href;
      return pdfjsLib;
    },
  );

  async function loadDocument(url) {
    let entry = documents.get(url);
    if (entry) {
      return entry.promise;
    }

    const pdfjsLib = await pdfJsReady;
    const task = pdfjsLib.getDocument({
      url: url,
      cMapUrl: pdfJsAssets + 'cmaps/',
      cMapPacked: true,
      standardFontDataUrl: pdfJsAssets + 'standard_fonts/',
      wasmUrl: pdfJsAssets + 'wasm/',
      disableRange: true,
      disableStream: true,
      disableAutoFetch: true,
      isEvalSupported: false,
    });
    entry = { task: task, promise: task.promise };
    documents.set(url, entry);
    try {
      return await entry.promise;
    } catch (error) {
      documents.delete(url);
      throw error;
    }
  }

  window.scholarsRenderPdfPage = async function (
    url,
    requestedPage,
    maxDimension,
  ) {
    const pdf = await loadDocument(url);
    const pageNumber = Math.max(
      1,
      Math.min(Number(requestedPage) || 1, pdf.numPages),
    );
    const page = await pdf.getPage(pageNumber);
    const baseViewport = page.getViewport({ scale: 1 });
    const longestSide = Math.max(baseViewport.width, baseViewport.height);
    const scale = Math.max(
      1,
      Math.min(3, Number(maxDimension) / longestSide),
    );
    const viewport = page.getViewport({ scale: scale });
    const canvas = document.createElement('canvas');
    canvas.width = Math.ceil(viewport.width);
    canvas.height = Math.ceil(viewport.height);
    const context = canvas.getContext('2d', { alpha: false });
    if (!context) {
      throw new Error('This browser could not create a PDF canvas.');
    }
    context.fillStyle = '#ffffff';
    context.fillRect(0, 0, canvas.width, canvas.height);

    await page.render({
      canvas: canvas,
      canvasContext: context,
      viewport: viewport,
      background: '#ffffff',
    }).promise;

    const blob = await new Promise(function (resolve, reject) {
      canvas.toBlob(function (value) {
        if (value) {
          resolve(value);
        } else {
          reject(new Error('The PDF page could not be converted.'));
        }
      }, 'image/png');
    });
    page.cleanup();
    canvas.width = 1;
    canvas.height = 1;
    return {
      imageUrl: URL.createObjectURL(blob),
      pageCount: pdf.numPages,
    };
  };

  window.scholarsRevokePdfPageImage = function (imageUrl) {
    URL.revokeObjectURL(imageUrl);
  };

  window.scholarsDisposePdfDocument = function (url) {
    const entry = documents.get(url);
    documents.delete(url);
    if (!entry) {
      return;
    }
    entry.promise.then(
      function (pdf) {
        pdf.destroy();
      },
      function () {},
    );
  };
})();
