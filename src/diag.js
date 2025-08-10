// loaded globally in app.module.js

// call with method name and "arguments" object
function formatLogLine(name, args, maxLen = 1000) {
  const formattedArgs = Array.prototype.slice.call(args).map((arg) => {
    if (typeof arg === "object") {
      try {
        const str = JSON.stringify(arg);
        return str.length > maxLen ? str.slice(0, maxLen) + "..." : str;
      } catch {
        return "[Err]";
      }
    }
    return arg !== undefined ? arg : "";
  });

  logLine = `> ${name}() ${formattedArgs.join(" ")}`;

  return logLine;
}

module.exports = {
  formatLogLine,
};

console.log("Loading diag.js");
