import React from "react";
import { createRoot } from "react-dom/client";
import { SidepanelApp } from "./SidepanelApp";
import "@gcsa-aegis/ui/styles.css";

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <SidepanelApp />
  </React.StrictMode>,
);
