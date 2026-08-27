import React from "react";
import { createRoot } from "react-dom/client";
import { OptionsApp } from "./OptionsApp";
import "@gcsa-aegis/ui/styles.css";

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <OptionsApp />
  </React.StrictMode>,
);
