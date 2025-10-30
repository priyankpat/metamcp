import { genericOAuthClient } from "better-auth/client/plugins";
import { createAuthClient } from "better-auth/react";

import { getAppUrl, getBasePath } from "./env";

export const authClient = createAuthClient({
  baseURL: getAppUrl().replace(getBasePath(), ""),
  plugins: [genericOAuthClient()],
}) as ReturnType<typeof createAuthClient>;
