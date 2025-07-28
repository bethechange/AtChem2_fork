#!/usr/bin/env Rscript
# generate_isopleth.R
# Author: SB
# Date: `r Sys.Date()`

suppressPackageStartupMessages({
  library(data.table)
  library(tidyverse)
  library(plotly)
  library(htmlwidgets)
  library(fuzzyjoin)   # if you still need it elsewhere
  library(lookup)
  # optional helpers, install if you like:
  # library(here)
  # library(optparse)
})

## --------------------------------
## 1. Resolve project root & config
## --------------------------------
# Try git root first, then fall back to cwd
get_project_root <- function() {
  root <- tryCatch(system("git rev-parse --show-toplevel", intern = TRUE), error = function(e) NA)
  if (is.na(root) || length(root) == 0) normalizePath(".", winslash = "/", mustWork = TRUE) else root
}
PROJECT_ROOT <- get_project_root()

CONFIG_FILE_DEFAULT <- file.path(PROJECT_ROOT, "tools", "plot", "isopleth", "isopleth_config.sh")

# Allow override via env var or --config arg
args <- commandArgs(trailingOnly = TRUE)
cfg_arg_idx <- which(grepl("^--config=", args))
CONFIG_FILE <- if (length(cfg_arg_idx)) sub("^--config=", "", args[cfg_arg_idx]) else
  Sys.getenv("ISOPLETHR_CONFIG_FILE", CONFIG_FILE_DEFAULT)

if (!file.exists(CONFIG_FILE)) {
  stop("Config file not found: ", CONFIG_FILE,
       "\nPass --config=/path/to/isoplethr_config.sh or set ISOPLETHR_CONFIG_FILE.")
}

# Source shell config safely and capture needed vars
read_shell_vars <- function(sh_file, vars = c("ISOPLETHR_CONFIG_NAME", "OUTPUT_FOLDER")) {
  # Build echo statements so we only capture what we ask for
  echo_cmds <- paste0("echo ", vars, "=${", vars, "}")
  cmd <- sprintf("bash -c 'set -a; source %s >/dev/null 2>&1; %s'", shQuote(sh_file), paste(echo_cmds, collapse = "; "))
  out <- system(cmd, intern = TRUE)
  key_val <- strsplit(out, "=", fixed = TRUE)
  out_list <- setNames(lapply(key_val, function(x) if (length(x) == 2) x[2] else NA_character_), vapply(key_val, `[`, "", 1))
  out_list
}
cfg <- read_shell_vars(CONFIG_FILE)

if (is.na(cfg$OUTPUT_FOLDER) || cfg$OUTPUT_FOLDER == "") {
  if (is.na(cfg$ISOPLETHR_CONFIG_NAME) || cfg$ISOPLETHR_CONFIG_NAME == "") {
    stop("Neither OUTPUT_FOLDER nor ISOPLETHR_CONFIG_NAME were defined in ", CONFIG_FILE)
  } else {
    cfg$OUTPUT_FOLDER <- file.path(PROJECT_ROOT, "output", cfg$ISOPLETHR_CONFIG_NAME)
  }
} else {
  # make absolute if relative
  if (!grepl("^/", cfg$OUTPUT_FOLDER)) {
    cfg$OUTPUT_FOLDER <- file.path(PROJECT_ROOT, cfg$OUTPUT_FOLDER)
  }
}
TARGET_DIR <- normalizePath(cfg$OUTPUT_FOLDER, winslash = "/", mustWork = TRUE)

PLOTS_DIR <- file.path(TARGET_DIR, "plots")
dir.create(PLOTS_DIR, recursive = TRUE, showWarnings = FALSE)

message("Target data dir    : ", TARGET_DIR)
message("Plots output dir   : ", PLOTS_DIR)

## -----------------------------
## 2. Locate input files
## -----------------------------
text_files <- list.files(TARGET_DIR, pattern = "concs", full.names = TRUE)
if (length(text_files) == 0) stop("No files matching 'concs' found in ", TARGET_DIR)

## -----------------------------
## 3. Read & prep data
## -----------------------------
# Use first file to define the numeric schema
first_file <- fread(text_files[1])

# Assume first column is time / index, rest numeric species  (adjust to your format)
num_cols <- names(first_file)[2:ncol(first_file)]

first_max_diff <- data.table(matrix(ncol = length(num_cols), nrow = 0))
first_last_diff <- data.table(matrix(ncol = length(num_cols), nrow = 0))
first_val      <- data.table(matrix(ncol = length(num_cols), nrow = 0))

setnames(first_max_diff, num_cols)
setnames(first_last_diff, num_cols)
setnames(first_val,      num_cols)

for (file in text_files) {
  dt <- fread(file)
  # store first numeric row
  first_values <- dt[1, ..num_cols]
  first_val <- rbindlist(list(first_val, first_values), use.names = TRUE, fill = TRUE)
  # diffs
  max_diff  <- dt[, lapply(.SD, function(x) max(x, na.rm = TRUE) - x[1]), .SDcols = num_cols]
  last_diff <- dt[, lapply(.SD, function(x) x[.N] - x[1]), .SDcols = num_cols]
  first_max_diff  <- rbindlist(list(first_max_diff,  max_diff),  use.names = TRUE, fill = TRUE)
  first_last_diff <- rbindlist(list(first_last_diff, last_diff), use.names = TRUE, fill = TRUE)
}

# free
rm(first_file, file, first_values, max_diff, last_diff, dt)

first_last_diff <- as.data.frame(first_last_diff)
first_max_diff  <- as.data.frame(first_max_diff)
first_val_df    <- as.data.frame(first_val)

## -----------------------------
## 4. Reference (zero_H2O2) & lookups
## -----------------------------
zero_H2O2 <- subset(cbind(first_val_df, setNames(first_last_diff, paste0(num_cols, "_diff"))),
                    H2O2 == 0)

# Helper to build base_* vectors via lookup over NO
build_base <- function(name) {
  lookup(x = first_val_df$NO,
         key = zero_H2O2$NO,
         value = zero_H2O2[[paste0(name, "_diff")]],
         nomatch = 0)
}

ref_val_H2O2 <- sapply(num_cols, build_base) %>% as.data.frame()
names(ref_val_H2O2) <- colnames(first_last_diff)

## -----------------------------
## 5. Derived tables
## -----------------------------
# mol per mol H2O2
effective_final_change_per_H2O2 <- (first_last_diff - ref_val_H2O2) / first_val_df[["H2O2"]]
effective_max_change_per_H2O2   <- (first_max_diff  - ref_val_H2O2) / first_val_df[["H2O2"]]

# convert to ppb (2.46e10 molecules/cm3 at STP; adjust if needed)
ppb_conv <- 2.46e10
effective_final_change <- (first_last_diff - ref_val_H2O2) / ppb_conv
effective_max_change   <- (first_max_diff  - ref_val_H2O2) / ppb_conv

# extra molecules per methane removed
extra_molecules_per_methane_removed <- effective_final_change / effective_final_change$CH4

# Flip methane sign for visualization clarity
effective_final_change_per_H2O2$CH4 <- -effective_final_change_per_H2O2$CH4
effective_final_change$CH4          <- -effective_final_change$CH4

## -----------------------------
## 6. Log transforms (safe)
## -----------------------------
safe_log10 <- function(x) {
  out <- log10(x)
  out[!is.finite(out)] <- NA
  out
}

fv <- first_val_df
fv$H2O2 <- safe_log10(fv$H2O2)
fv$NO   <- safe_log10(fv$NO)

effective_max_change_per_H2O2$O3 <- safe_log10(effective_max_change_per_H2O2$O3)
effective_max_change$O3          <- safe_log10(effective_max_change$O3)
effective_final_change$O3        <- safe_log10(effective_final_change$O3)

## -----------------------------
## 7. Plotly figures
## -----------------------------
# Helper constructor for a 3D scatter
mk3d <- function(zdata, nm, zlab = "Change") {
  plot_ly(fv,
          x = ~H2O2,
          y = ~NO,
          z = ~zdata,
          type = "scatter3d",
          mode = "markers",
          name = nm) %>%
    layout(scene = list(
      xaxis = list(title = "log10(H2O2)"),
      yaxis = list(title = "log10(NO)"),
      zaxis = list(title = zlab)
    ))
}

p1  <- mk3d(effective_final_change_per_H2O2$CH4,  "CH4_removed (mol/mol H2O2)")
p2  <- mk3d(effective_final_change_per_H2O2$CO,   "CO_added (mol/mol H2O2)")
p3  <- mk3d(effective_final_change_per_H2O2$O3,   "O3_added (mol/mol H2O2)")
p4  <- mk3d(effective_max_change_per_H2O2$O3,     "Max O3_log10 (mol/mol H2O2)")
p5  <- mk3d(effective_final_change$CH4,           "CH4_ppb")
p6  <- mk3d(effective_final_change$CO,            "CO_ppb")
p7  <- mk3d(effective_final_change$O3,            "O3_log10ppb")
p8  <- mk3d(effective_max_change$O3,              "Max O3_log10ppb")
p9  <- mk3d(extra_molecules_per_methane_removed$O3,    "Extra_O3_per_CH4_mol")
p10 <- mk3d(extra_molecules_per_methane_removed$HCHO,  "Extra_HCHO_per_CH4_mol")
p11 <- mk3d(extra_molecules_per_methane_removed$CH3CHO,"Extra_CH3CHO_per_CH4_mol")
p12 <- mk3d(extra_molecules_per_methane_removed$CH3OH, "Extra_CH3OH_per_CH4_mol")

# Combine all figures into a single HTML.
# Option A: subplot grid (keeps them separate but in one HTML)
fig <- subplot(p1, p2, p3, p4,
               p5, p6, p7, p8,
               p9, p10, p11, p12,
               nrows = 3, margin = 0.03, shareX = FALSE, shareY = FALSE)

# Option B (commented): Put all traces into one 3D scene and toggle by legend
# fig <- plotly::plot_ly()
# add_trace loops here...

# Save widget
html_file <- file.path(PLOTS_DIR, sprintf("isopleth_%s.html", format(Sys.time(), "%Y%m%d_%H%M%S")))
saveWidget(fig, file = html_file, selfcontained = TRUE)
message("✔ Saved HTML to: ", html_file)

invisible(NULL)
