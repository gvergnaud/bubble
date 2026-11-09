// One page, two routes (docs/editor-api.md §1): "/" is the home page (recent videos, open,
// drop), "/edit/:id" the editor. The markup of each is a <template> in index.html; it is put
// in the body before its module runs, since both look their elements up when they load.
const home = location.pathname === "/" || location.pathname === "";
const tpl = document.getElementById(home ? "tpl-home" : "tpl-editor");
document.body.append(tpl.content.cloneNode(true));
if (home) {
  document.body.classList.add("home-page");
  document.title = "Bubble";
  await import("./home.js");
} else {
  await import("./app.js");
}
