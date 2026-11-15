// Runs inside the page when someone shares from Safari. It hands the address and the
// rendered page to the extension, so the server does not need to fetch the page itself.
var GetPage = function () {};

GetPage.prototype = {
  run: function (args) {
    args.completionFunction({
      url: document.URL,
      title: document.title,
      html: document.documentElement.outerHTML,
    });
  },
  finalize: function () {},
};

var ExtensionPreprocessingJS = new GetPage();
