const fs = require("fs");

function addLoggingToFile(filePath, ignoreFunc, includeFunc) {
  try {
    const content = fs.readFileSync(filePath, "utf8");

    const funcPattern = /^( *)(?:private )?(?:async )?([a-zA-Z0-9_]+)\([^)]*\)[^{\n]*\{ *$/gm;

    // enable function call tracing
    //   add log statement next to the func header line
    //   add comment on the func header line, this ensures idempotence when re-running the patch
    let isModified = false;
    let newContent = content.replace(funcPattern, (match, indentation, name) => {
      const comment = ` // patched by diag.js`;
      const log = `${indentation}  this.logger.verbose(diag.formatLogLine("${name}", arguments));`;

      // skip ignored functions
      if (ignoreFunc.includes(name)) {
        return match;
      }
      isModified = true;
      return `${match}${comment}\n${log}`;
    });

    // write back to the file, create backup if not exists
    const filePathBak = `${filePath}.bak`;
    if (!fs.existsSync(filePathBak)) {
      fs.copyFileSync(filePath, filePathBak);
    }
    fs.writeFileSync(filePath, newContent, "utf8");

    if (isModified) {
      console.log(`[+] Patched: ${filePath}`);
    } else {
      console.log(`[.] Processed: ${filePath}. No changes.`);
    }
    return true;
  } catch (error) {
    console.error(`[-] Error processing: ${filePath}:`, error);
    return false;
  }
}

function addLoggingToFiles(filePaths) {
  const ignoreFunc = [
    "constructor",
    "setup",
    "getJobStatus",
    "getJobCounts",
    "getQueue",
    "getQueueStatus",
    "isConcurrentQueue",
  ];
  let numFilesPatched = 0;

  for (const filePath of filePaths) {
    if (!fs.existsSync(filePath)) {
      console.error(`[ ] Not found: ${filePath}`);
      continue;
    }
    if (addLoggingToFile(filePath, ignoreFunc)) {
      numFilesPatched++;
    }
  }
}

const args = process.argv.slice(2); // skip node and script
if (args.length === 0) {
  console.error("Usage: node server/dist/bin/diag-add-logging.js <file1> <file2> ...");
  console.error("Example: node diag.js server/dist/services/job.service.js server/dist/repositories/job.repository.js");
  process.exit(1);
}

addLoggingToFiles(args);
