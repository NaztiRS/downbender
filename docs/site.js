(() => {
  "use strict";

  const status = document.getElementById("copy-status");

  async function copyText(value) {
    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch {
      const field = document.createElement("textarea");
      field.value = value;
      field.setAttribute("readonly", "");
      field.style.position = "fixed";
      field.style.opacity = "0";
      document.body.append(field);
      field.select();
      const copied = document.execCommand("copy");
      field.remove();
      return copied;
    }
  }

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const original = button.textContent;
      const copied = await copyText(button.dataset.copy || "");

      button.textContent = copied ? "Copied ✓" : "Try again";
      button.classList.toggle("is-copied", copied);
      if (status) {
        status.textContent = copied
          ? "Command copied to the clipboard."
          : "The command could not be copied.";
      }

      window.setTimeout(() => {
        button.textContent = original;
        button.classList.remove("is-copied");
      }, 1800);
    });
  });

})();
