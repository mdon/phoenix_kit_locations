// Prebuilt LiveView hooks for phoenix_kit_locations. Declared via `js_sources/0`;
// core's `:phoenix_kit_js_sources` compiler concatenates this (IIFE-wrapped)
// into the host's `phoenix_kit_modules.js` and folds
// `window.PhoenixKitLocationsHooks` into `window.PhoenixKitHooks`.
window.PhoenixKitLocationsHooks = window.PhoenixKitLocationsHooks || {};

// PhoenixKitLocationsUploadScope — on a files card's dropzone. A location's
// page shows one card per scope (the location, each of its spaces) and they
// share one upload, so the server has to know which card a file is for.
// A click tells it through `phx-click`; a file dragged straight in never
// clicks, so this tells it on `dragenter`, well before the `drop` the upload
// listens for.
window.PhoenixKitLocationsHooks.PhoenixKitLocationsUploadScope = {
  mounted: function () {
    var hook = this;
    this.onDragEnter = function () {
      var scope = hook.el.dataset.scope;
      if (scope) hook.pushEvent("set_active_upload_scope", { scope: scope });
    };
    this.el.addEventListener("dragenter", this.onDragEnter);
  },
  destroyed: function () {
    this.el.removeEventListener("dragenter", this.onDragEnter);
  },
};
