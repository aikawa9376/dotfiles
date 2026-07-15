local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function assert_truthy(value, label)
  if not value then
    error(label or "expected truthy value", 2)
  end
end

function M.run()
  local Security = require("lazyagent.acp.mobile_security")
  local token = assert(Security.random_token())
  local other = assert(Security.random_token())
  assert_equal(64, #token, "token length")
  assert_truthy(token:match("^%x+$"), "token is hexadecimal")
  assert_truthy(token ~= other, "tokens are random")

  assert_equal(true, Security.authorized({ headers = { authorization = "Bearer " .. token } }, token), "bearer auth")
  assert_equal(false, Security.authorized({ headers = { authorization = "Bearer wrong" } }, token), "wrong bearer")
  assert_equal(true, Security.authorized({ headers = {} }, token, token), "query auth")

  assert_equal(true, Security.origin_allowed({ headers = {} }), "non-browser origin")
  assert_equal(true, Security.origin_allowed({
    headers = { origin = "http://192.168.1.2:39280", host = "192.168.1.2:39280" },
  }), "same origin")
  assert_equal(false, Security.origin_allowed({
    headers = { origin = "https://evil.example", host = "127.0.0.1:39280" },
  }), "foreign origin")
  assert_equal(true, Security.origin_allowed({
    headers = { origin = "https://trusted.example", host = "127.0.0.1:39280" },
  }, { "https://trusted.example" }), "allowlisted origin")

  assert_equal(true, Security.body_allowed(262144, 262144), "body at limit")
  assert_equal(false, Security.body_allowed(262145, 262144), "body over limit")
  assert_equal(false, Security.body_allowed(-1, 262144), "negative body")
  assert_equal(true, Security.is_loopback("127.0.0.1"), "loopback")
  assert_equal(false, Security.is_loopback("0.0.0.0"), "wildcard is public")
end

return M
