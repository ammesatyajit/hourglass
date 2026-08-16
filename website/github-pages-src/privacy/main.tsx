import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import PrivacyPolicy from "../../app/privacy/page";
import "../../app/globals.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode><PrivacyPolicy /></StrictMode>,
);
