import type { Metadata } from "next";
import "./globals.css";

const url = "https://diffreview.dev";
const description =
  "Your AI writes the code — DiffReview is where you review it. A native macOS app that shows the whole branch as one diff, collects your line comments, and copies them back to your coding agent as one prompt.";

export const metadata: Metadata = {
  title: "DiffReview — Native Code Review for macOS",
  description,
  metadataBase: new URL(url),
  openGraph: {
    title: "DiffReview",
    description,
    url,
    siteName: "DiffReview",
    type: "website",
  },
  twitter: {
    card: "summary",
    title: "DiffReview",
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
