#!/usr/bin/env Rscript
# generate_isopleth.R
# Scott Bell | IPTL
# ---------------------------------------------------------------

suppressPackageStartupMessages({
  library(data.table)
  library(plotly)
  library(tidyverse)
  library(htmlwidgets)
  library(lookup)
})

# ---------
# For interactive debug: set cfg_path manually
if (!exists("cfg_path")) {
  cfg_path <- "/home/s/IPTL/Ubuntu/AtChem2_fork/tools/plot/isopleth/isopleth_config.sh"
  message("Using config: ", cfg_path)
}
# ---------

## ------------------------------------------------------------------
## 0.  ── command-line ------------------------------------------------
## ------------------------------------------------------------------
args      <- commandArgs(trailingOnly = TRUE)
cfg_path  <- sub("^--config=",      "", args[grepl("^--config=",      args)])
out_dir   <- sub("^--output-dir=",  "", args[grepl("^--output-dir=",  args)])
conc_dir  <- sub("^--conc-dir=",    "", args[grepl("^--conc-dir=",    args)])

if (cfg_path == "") stop("Missing --config=<isopleth_config.sh>")
if (!file.exists(cfg_path)) stop("Config file not found: ", cfg_path)
cfg_lines <- readLines(cfg_path)

# crude shell-array parsers...
get_scalar <- function(var) {
  m <- grep(sprintf("^%s=", var), cfg_lines, value = TRUE)
  if (length(m)) sub(sprintf("^%s=['\"]?([^'\"]+)['\"]?.*$", var), "\\1", m) else NA_character_
}
get_array  <- function(var) {
  m <- grep(sprintf("^%s=.*\\(", var), cfg_lines, value = TRUE)
  if (!length(m)) return(character(0))
  body <- sub(sprintf("^%s=.*\\(([^)]*)\\).*", var), "\\1", m)
  trimws(strsplit(body, "[[:space:]]+")[[1]])
}

scan1  <- get_scalar("SCAN_SPECIES_1")
scan2  <- get_scalar("SCAN_SPECIES_2")
removed_species <- get_array("ISOPLETH_REMOVED_SPECIES")
if (length(removed_species) == 0)
  stop("ISOPLETH_REMOVED_SPECIES not found (or empty) in config.")

if (out_dir == "") {
  out_dir <- get_scalar("OUTPUT_ROOT")
  if (out_dir == "") stop("Pass --output-dir or set OUTPUT_ROOT in config.")
}
out_dir    <- normalizePath(out_dir, winslash = "/", mustWork = TRUE)
plots_dir  <- file.path(out_dir, "plots"); dir.create(plots_dir, showWarnings = FALSE)

# >>> ADD THIS BLOCK <<<
if (conc_dir == "") {
  conc_dir <- out_dir  # default to out_dir if not set
}
conc_dir <- normalizePath(conc_dir, winslash = "/", mustWork = TRUE)
message("✓ Using output dir: ", out_dir)
message("✓ Looking for concentration files in: ", conc_dir)


## ------------------------------------------------------------------
## 1.  ── locate & load simulation output ----------------------------
## ------------------------------------------------------------------
# Find and sort files numerically: atchem2_concs_1.txt, ..., _25.txt
txt_files <- list.files(conc_dir, "^atchem2_concs_([0-9]+)\\.txt$", full.names = TRUE)
if (!length(txt_files)) txt_files <- list.files(conc_dir, "concs", full.names = TRUE)

if (length(txt_files)) {
  idx <- as.integer(sub(".*_([0-9]+)\\.txt$", "\\1", basename(txt_files)))
  o   <- order(idx)
  txt_files <- txt_files[o]
}

if (!length(txt_files)) stop("No concentration files found in ", conc_dir)


first_dt   <- fread(txt_files[1])
num_cols   <- names(first_dt)[2:ncol(first_dt)]

fst_max <- fst_last <- fst_val <- data.table(matrix(nrow = 0, ncol = length(num_cols)))
setnames(fst_max,  num_cols); setnames(fst_last, num_cols); setnames(fst_val, num_cols)

for (f in txt_files) {
  dt <- fread(f)
  fst_val  <- rbind(fst_val,  dt[1, ..num_cols])
  fst_max  <- rbind(fst_max,  dt[, lapply(.SD, \(x) max(x, na.rm = TRUE) - x[1]), .SDcols = num_cols])
  fst_last <- rbind(fst_last, dt[, lapply(.SD, \(x) x[.N]             - x[1]), .SDcols = num_cols])
}

fst_val   <- as.data.frame(fst_val)
fst_max   <- as.data.frame(fst_max)
fst_last  <- as.data.frame(fst_last)

## ------------------------------------------------------------------
## 2.  ── helpers ----------------------------------------------------
## ------------------------------------------------------------------
safe_log10 <- function(x) { o <- log10(x); o[!is.finite(o)] <- NA; o }

build_reference <- function(zero_sp, other_sp) {
  zeros <- fst_val[[zero_sp]] == 0
  zs    <- cbind(fst_val[zeros, ], setNames(fst_last[zeros, ], paste0(num_cols, "_diff")))
  ref <- sapply(num_cols, \(nm) {
    lookup(fst_val[[other_sp]], zs[[other_sp]], zs[[paste0(nm, "_diff")]], nomatch = 0)
  }) |> as.data.frame()
  names(ref) <- names(fst_last); ref
}


derive_tables <- function(ref_val, scan_sp, ppb_conv = 2.46e10) {
  fin_per <- (fst_last - ref_val) / fst_val[[scan_sp]]
  max_per <- (fst_max  - ref_val) / fst_val[[scan_sp]]
  fin_ppb <- (fst_last - ref_val) / ppb_conv
  max_ppb <- (fst_max  - ref_val) / ppb_conv

  # methane sign flip
  if ("CH4" %in% names(fin_per)) {
    fin_per$CH4 <- -fin_per$CH4
    fin_ppb$CH4 <- -fin_ppb$CH4
  }
  list(fin_per = fin_per,
       max_per = max_per,
       fin_ppb = fin_ppb,
       max_ppb = max_ppb,
       extra   = fin_ppb / fin_ppb$CH4)
}

mk3d <- function(df_xy, x_var, y_var, z_vec, title, zlab = "Δ") {
  plot_ly(df_xy,
          x = as.formula(paste0("~", x_var)),
          y = as.formula(paste0("~", y_var)),
          z = ~z_vec,
          type = "scatter3d", mode = "markers",
          name = title) |>
    layout(scene = list(
      xaxis = list(title = paste0("log10(", x_var, ")")),
      yaxis = list(title = paste0("log10(", y_var, ")")),
      zaxis = list(title = zlab)
    ))
}

save_fig <- function(p_list, fname) {
  rows <- ceiling(sqrt(length(p_list)))
  fig  <- subplot(p_list, nrows = rows, margin = 0.03)
  html <- file.path(plots_dir, fname)
  saveWidget(fig, html, selfcontained = TRUE); message("✔ wrote ", basename(html))
}

## ------------------------------------------------------------------
## 3.  ── analyse each scan dimension --------------------------------
## ------------------------------------------------------------------
process_dimension <- function(scan_sp, other_sp, tag) {

  ref      <- build_reference(scan_sp, other_sp)
  effects  <- derive_tables(ref, scan_sp)

  # for plotting we need log10 of both scan axes
  df_xy <- fst_val
  df_xy[[scan_sp]]  <- safe_log10(df_xy[[scan_sp]])
  df_xy[[other_sp]] <- safe_log10(df_xy[[other_sp]])

  p_all <- list()
  for (sp in removed_species) {

    # 3a  final change (ppb)
    if (sp %in% names(effects$fin_ppb))
      p_all[[length(p_all)+1]] <-
        mk3d(df_xy, scan_sp, other_sp, effects$fin_ppb[[sp]],
             sprintf("%s final Δ(ppb)", sp), "Δ(ppb)")

    # 3b  max change (ppb)
    if (sp %in% names(effects$max_ppb))
      p_all[[length(p_all)+1]] <-
        mk3d(df_xy, scan_sp, other_sp, effects$max_ppb[[sp]],
             sprintf("%s max Δ(ppb)", sp), "Δ(ppb)")

    # 3c  final change per scan species (mol/mol)
    if (sp %in% names(effects$fin_per))
      p_all[[length(p_all)+1]] <-
        mk3d(df_xy, scan_sp, other_sp, effects$fin_per[[sp]],
             sprintf("%s final Δ per %s", sp, scan_sp), "mol · mol⁻¹")

    # 3d  extra molecules per CH4 removed (skip CH4 itself)
    if (sp != "CH4" && "CH4" %in% names(effects$extra))
      p_all[[length(p_all)+1]] <-
        mk3d(df_xy, scan_sp, other_sp, effects$extra[[sp]],
             sprintf("extra %s per CH4 removed", sp), "ratio")
  }

  fname <- sprintf("isopleth_%s_%s.html",
                   format(Sys.time(), "%Y%m%d_%H%M%S"), tag)
  save_fig(p_all, fname)
}

process_dimension(scan1, scan2, paste0("scan_", tolower(scan1)))
process_dimension(scan2, scan1, paste0("scan_", tolower(scan2)))
