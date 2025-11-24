"use client";

import { useRouter } from "next/navigation";
import { useEffect } from "react";

import { useTranslations } from "@/hooks/useTranslations";
import { getBasePath } from "@/lib/env";

export default function RootPage() {
  const { t, locale } = useTranslations();
  const router = useRouter();

  useEffect(() => {
    // Redirect to MCP servers page as the new default
    router.replace(`${getBasePath()}/${locale}/mcp-servers`);
  }, [locale, router]);

  // Return a loading state while redirecting
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">
          {t("common:loading")}
        </h1>
      </div>
    </div>
  );
}
