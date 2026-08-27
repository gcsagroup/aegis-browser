import React from "react";
import { createRoot } from "react-dom/client";
import { PopupApp } from "./PopupApp";
import "@gcsa-aegis/ui/styles.css";

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <PopupApp />
  </React.StrictMode>,
);
