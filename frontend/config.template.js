// config.template.js — safe to commit
// deploy.sh generates config.js from Terraform outputs.
// Do NOT edit config.js directly — it is gitignored and overwritten on deploy.
//
// To run locally against a deployed stack, copy this file to config.js
// and fill in your API Gateway URL from: terraform output api_gateway_url

const CONFIG = {
  apiBaseUrl: "https://YOUR_API_GATEWAY_ID.execute-api.us-east-1.amazonaws.com/v1",
};
