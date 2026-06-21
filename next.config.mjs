/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // The service layer uses native pg via postgres.js; keep it server-external.
  serverExternalPackages: ["postgres", "bcryptjs"],
};

export default nextConfig;
