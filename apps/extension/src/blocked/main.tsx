import React from "react";
import { createRoot } from "react-dom/client";
import { BlockedApp } from "./BlockedApp";
import "@gcsa-aegis/ui/styles.css";

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <BlockedApp />
  </React.StrictMode>,
);
