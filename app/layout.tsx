import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { AuthHashRedirect } from "@/components/auth-hash-redirect";
import { AUTH_HASH_REDIRECT_SCRIPT } from "@/lib/auth-hash";
import { Toaster } from "sonner";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Open Ledger",
  description: "Open Ledger - Open-source accounting for early-stage companies",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col bg-background text-foreground font-sans">
        <script dangerouslySetInnerHTML={{ __html: AUTH_HASH_REDIRECT_SCRIPT }} />
        <AuthHashRedirect />
        <Toaster position="top-center" />
        {children}
      </body>
    </html>
  );
}
