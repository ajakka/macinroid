// Small touches; the page works without them.

const repository = "anyfikra/macinroid";

// Point the download buttons at the newest release's zip, and show its version.
fetch(`https://api.github.com/repos/${repository}/releases/latest`)
  .then((response) => (response.ok ? response.json() : null))
  .then((release) => {
    if (!release) return;
    const zip = release.assets.find((asset) => asset.name.endsWith(".zip"));
    if (zip) {
      for (const link of document.querySelectorAll("[data-download]")) link.href = zip.browser_download_url;
    }
    const version = release.tag_name.replace(/^v/i, "");
    for (const label of document.querySelectorAll("[data-version]")) label.textContent = `Free · Version ${version}`;
  })
  .catch(() => {});

// Copy the Homebrew command.
for (const button of document.querySelectorAll("[data-copy]")) {
  const label = button.querySelector(".copy");
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      label.textContent = "Copied";
    } catch {
      label.textContent = "Select and copy";
    }
    setTimeout(() => (label.textContent = "Copy"), 2000);
  });
}

// Let sections rise into place as they scroll into view.
const reveals = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("shown");
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.12 }
  );
  reveals.forEach((element) => observer.observe(element));
} else {
  reveals.forEach((element) => element.classList.add("shown"));
}
