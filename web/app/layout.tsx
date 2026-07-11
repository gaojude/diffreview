import type { Metadata } from "next";
import "./globals.css";

const url = "https://redline.dev";
const description =
  "Your AI writes the code — Redline is where you review it. A native macOS app that shows the whole branch as one diff, collects your line comments, and copies them back to your coding agent as one prompt.";

export const metadata: Metadata = {
  title: "Redline — Native Code Review for macOS",
  description,
  metadataBase: new URL(url),
  openGraph: {
    title: "Redline",
    description,
    url,
    siteName: "Redline",
    type: "website",
  },
  twitter: {
    card: "summary",
    title: "Redline",
    description,
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
