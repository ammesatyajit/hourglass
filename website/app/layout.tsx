import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://ammesatyajit.github.io/hourglass/"),
  title: {
    default: "Hourglass — iMessage search and analytics",
    template: "%s · Hourglass",
  },
  description: "Search every iMessage. Explore the language your circles share. Everything stays on your Mac.",
  icons: {
    icon: "hourglass-icon.png",
    shortcut: "hourglass-icon.png",
    apple: "hourglass-icon.png",
  },
  openGraph: {
    title: "Hourglass",
    description: "iMessage search and analytics",
    type: "website",
    url: "https://ammesatyajit.github.io/hourglass/",
    images: [{ url: "og-dark.png", width: 1200, height: 630, alt: "Hourglass for macOS" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Hourglass",
    description: "iMessage search and analytics",
    images: ["og-dark.png"],
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
