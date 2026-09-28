// Theme toggle for the app-store pages.
//
// The pages carry no data-theme attribute. That is deliberate: the generated tokens already have
// a `@media (prefers-color-scheme: dark)` layer, so the correct theme is painted on the first
// frame and this script only has to honour a choice made on an earlier visit. Setting the
// attribute from script on every load, as this used to, is what produces the flash of the wrong
// theme that the media query exists to avoid.
(function () {
  var root = document.documentElement;
  var key = "prabhix-store-theme";

  /** What the page is actually showing, whether that came from a saved choice or the system. */
  function current() {
    var set = root.getAttribute("data-theme");
    if (set === "light" || set === "dark") return set;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  var saved = localStorage.getItem(key);
  if (saved === "light" || saved === "dark") root.setAttribute("data-theme", saved);

  var btn = document.getElementById("theme-toggle");
  if (!btn) return;

  // The button's accessible name has to say which way it goes. It read "Toggle theme" in both
  // states, which tells a screen-reader user nothing about what pressing it will do.
  function label() {
    btn.setAttribute("aria-label", current() === "dark" ? "Switch to light theme" : "Switch to dark theme");
  }
  label();

  btn.addEventListener("click", function () {
    var next = current() === "dark" ? "light" : "dark";
    root.setAttribute("data-theme", next);
    localStorage.setItem(key, next);
    label();
  });

  // Following the system while no explicit choice has been made keeps the button's name honest
  // when the OS flips at sunset with the tab open.
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
    if (!localStorage.getItem(key)) label();
  });
})();
