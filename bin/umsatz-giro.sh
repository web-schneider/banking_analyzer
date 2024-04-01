#!/bin/bash
# umsatz-giro.sh - analyze giro account data
# Manfred Schneider (2024)
# %GIT-CONTROL% [~/Development/github.com/banking_analyzer]
#----------------------------------------------------------------------------------------------------


#----------------------------------------------------------------------------------------------------
# basic inits & defaults

export LANG=de_DE.UTF-8

# specific vars
source $HOME/.config/umsatz-giro.cfg

# internal vars
BASENAME=$(basename "$0")
OUTDIR="outdir"
WORKDIR="workdir"
PDF_HEADER=""  # init (customized pdf internal page header)
PREFIX=""      # init (customized output filename prefix)
#----------------------------------------------------------------------------------------------------


#----------------------------------------------------------------------------------------------------
function Display_Usage () {
 cat<<_EOH

 (prepare for terrible germish language mix ...)

 displays several umsaetze for moosach, unterfoehring, rente (=pension), etc..

 because the algo/regex has to fight often with vage and unclear dexcriptions or strings,
 you urgently need validate every record for correctness. 

 tool $BASENAME resides best in \$HOME/bin/
 configured by \$HOME/.config/${BASENAME%.sh}.cnf


 first download csv file(s) from SSKM to supply required csv files:
   mandatory CSV format => CAMT-V2
   mandatory file name  => $GIRODIR/giro-99999999-yyyymmdd-YYYYMMDD.camtv2.csv
                                                  ^^^^^^^^ ^^^^^^^^
                                                   -from-    -to-
     eg. $GIRODIR/giro-99999999-20230101-20231231.camtv2.csv


 required tools:
   - /usr/bin/iconv
   - /usr/bin/enscript

 current input CSV files:
$(eval ls -1 "$GIRODIR/$CSV_DEF" | awk '{printf("    %s\n", $0)}')

 program displays result formatted on screen and creates also output files:
   $GIRODIR/$OUTDIR/*.{csv,table,pdf}

 internal work directory:
   $GIRODIR/$WORKDIR/

 usage:
   $BASENAME -y YYYY -t TYPE [-k KONTO] [-p "pdf header text"] [-s positiv|negativ|all] [-h]

    -h help                ->  this help

    -y YEAR                ->  eg. 2023

    -t TYPE            [*] ->  option can be shortened but must be unique
       moos[*]             ->  Immobile moosach/oberwiesenfeld (Ein- und Ausgang)
       unterf[*]           ->  Immobile unterfoehring (Ein- und Ausgang)
       miete[*]            ->  Immobilen (alle) -> Mieteingang gesamt
       lohn|gehalt[*]      ->  Lohn & Gehalt (Siemens, KTM, ...) # lohn/gehalt/rente/pension können überlappen
       rente[*]            ->  gesetzliche Rente                 # lohn/gehalt/rente/pension können überlappen
       pension[*]          ->  Siemens Pension                   # lohn/gehalt/rente/pension können überlappen
       einku[*]            ->  Einkuenfte aus nicht-selbststaendiger Arbeit und nicht Vermietung
       kaufpreis[*]        ->  Immobile, Abschlagszahlungen/Kaufpreisraten
       steuer[*]           ->  all for Finanzamt pirates
       versich[*]          ->  diverse Versicherungsarten
       depot|wertpap[*]    ->  Wertpapiere & Depot
       erbe|schenkung[*]   ->  Erbschaften, Erbe, Schenkungen
       arzt[*]|medizin[*]  ->  Arzt, Medizin, Apotheke, Untersuchung
       eingang             ->  alle '+' Buchungen
       ausgang             ->  alle '-' Buchungen
       total               ->  alle Buchungen - nur sinnvoll mit p3 = positiv|negativ
       large               ->  sorted by large euro numbers (>= $LIMIT €)
       complete            ->  walk through most types in one command
       "search:what.*ever" ->  search for any string (case insensitiv, simple regex allowed)

   -k KONTO                ->  giro konto number (default internally configured)

   -p "pdf header text"    ->  any header text for pdf file, max. 80 chars (may be overwritten internally)

   -f "file_prefix"        ->  change leading part of file name from <type> to <file_prefix> [no special chars allowed]

   -s positiv|negativ|all  ->  (+- sign) accumulate EUR values either '+' or '-'

 examples:
   $BASENAME -y 2023 -t moosach   # (pdf header internally overwritten)
   $BASENAME -y 2022 -t steuer -s positiv
   $BASENAME -y 2021 -t "search:landeskrankenhilfe" -s negativ -p "LKH Krankenkasse in 2021"
   $BASENAME -y 2020 -t total -s positiv -p "alle Einnahmen in 2020"
   $BASENAME -y 2020 -t versicherungen -s negativ -p "Ausgaben fuer Versicherungen in 2020" 

 you may enter values or load the relevant $GIRODIR/$OUTDIR/???.csv file(s) into:
   $G_UND_V (if exists)

_EOH
}
#----------------------------------------------------------------------------------------------------


#----------------------------------------------------------------------------------------------------
# input

while getopts hk:y:t:p:f:s: OPTIONS
do
   case $OPTIONS in
        h) Display_Usage
           exit $? ;;

        k) KONTO="$OPTARG"
           ;;
 
        y) YEAR="$OPTARG"
           ;;
          
        t) TYPE="$OPTARG"
           ;;
          
        p) PDF_HEADER="$OPTARG"
           ;;

        s) SIGN="$OPTARG"
           ;;
          
        f) PREFIX="$OPTARG"
           # convert schrott-chars from prefix
           [ -n "$PREFIX" ] && PREFIX=$(sed 's/[^0-9a-zA-Z_-]/_/g' <<<"$OPTARG")
           ;;
          
        ?) echo "error ?: unknown option, call '$0 -h' for details"
           exit 1 ;;
          
        *) echo "error *: unknown option, call '$0 -h' for details"
           exit 1 ;;
   esac
done

# defaults
KONTO=${KONTO:=$DEF_KONTO}                                 # reset var to default
CSVPATT="giro-${KONTO}-????????-????????.camtv2.csv"       # format = CAMT-V2
CSV_COMPLETE="giro-${KONTO}-complete.csv"                  # all collected records in one file

[[ "$YEAR" != "" ]] || { echo "error: no year supplied"; exit 1; }
[[ "$TYPE" != "" ]] || { echo "error: no type supplied"; exit 1; }
[[ "$SIGN" =~ ^(negativ|positiv|all|)$ ]] || { echo "error: sign must be positiv|negativ|all|''"; exit 1; }

#----------------------------------------------------------------------------------------------------


#----------------------------------------------------------------------------------------------------
# check required tools

ICONV=$(type -p iconv) || { echo "error: required tool 'iconv' not available - please install"; exit 1; }
ENSCRIPT=$(type -p enscript) || { echo "error: required tool 'enscript' not available - please install"; exit 1; }
#----------------------------------------------------------------------------------------------------


#----------------------------------------------------------------------------------------------------
# csv formats
#
# CAMT-V2 header of giro-${KONTO}-????????-????????.camtv2.csv mandatory 17 cols (= 16 * ';')
# "Auftragskonto";"Buchungstag";"Valutadatum";"Buchungstext";"Verwendungszweck";"Glaeubiger ID";"Mandatsreferenz";"Kundenreferenz (End-to-End)";"Sammlerreferenz";"Lastschrift Ursprungsbetrag";"Auslagenersatz Ruecklastschrift";"Beguenstigter/Zahlungspflichtiger";"Kontonummer/IBAN";"BIC (SWIFT-Code)";"Betrag";"Waehrung";"Info"
#                                -----------   ------------   ----------------                                                                                                                                                     ---------------------------------                                         ------
# fields of interesst                $3             $4              $5                                                                                                                                                                          $12                          ($13)                            $15
# e.g.
# "DE54777777000099999999";"08.12.23";"08.12.23";"SEPA-ELV-LASTSCHRIFT";"987694857987984798792798798 ELVfhdg987fg 6.12 16.31 ME2";"DE4565460000078565";"G756756567576756ut5656";"00983457138745871348571038475918374";"";"";"";"HAGEBAU GERMERING DANKT";"DE75767547654670034535";"COBALLLLLLX";"-22,97";"EUR";"Umsatz gebucht"
#                                      --------   --------------------   -------------------------------------------------------                                                                                                -----------------------                                          ------
#                                        $3                $4                                       $5                                                                                                                                     $12                     ($13)                            $15
#
# old format 'mt940' must be converted to be used by this app -> insert ';;;;;;' between $5 and $6, 
# "Auftragskonto";"Buchungstag";"Valutadatum";"Buchungstext";"Verwendungszweck";"Beg�nstigter/Zahlungspflichtiger";"Kontonummer";"BLZ";"Betrag";"W�hrung";"Info"
#     ($1)             ($2)          $3             $4              $5                       $6                        ($7)       ($8)    $9      ($10)    ($11)
# "0980980980";"28.05";"28.05.10";"UMBUCHUNG";"GEHALT IKUHHLL MAI 2010 UEBERTRAG TEIL 1 DATUM 37.95.3010";"LKJHlll LKHHHJJJJ";"98767888";"45666663";"-1000,00";"EUR";"Umsatz gebucht"
#     ($1)       ($2)      $3         $4                              $5                                          $6             ($7)       ($8)        $9     ($10)     ($11)
#----------------------------------------------------------------------------------------------------



#----------------------------------------------------------------------------------------------------
# requirements
eval ls -1 "$GIRODIR/$CSVPATT" &>/dev/null || { echo "error: missing files '$GIRODIR/$CSVPATT'"; exit 1; }

umask 0077
cd "$GIRODIR"  # required !
[ -d "$GIRODIR/$OUTDIR" ]  || mkdir -p "$GIRODIR/$OUTDIR"
[ -d "$GIRODIR/$WORKDIR" ] || mkdir -p "$GIRODIR/$WORKDIR"
#----------------------------------------------------------------------------------------------------



#----------------------------------------------------------------------------------------------------
# convert csv file mime-encoding from individual (eg. ISO-8859-*) to UTF-8
#

# todo
# umlaute
# ä=xE4  ö=xF6  ü=xFC  Ä=xC4  Ö=xD6  Ü=xDC  ß=xDF

function MIME_CONVERT () {
 local CSV_FILE

 eval ls -1 "$GIRODIR/$CSVPATT" \
      | while read -r CSV_FILE
        do 
          ENCODING=$(file -b --mime-encoding "$CSV_FILE")
          ENCODING=${ENCODING^^}
          CSV_NAME=$(basename "$CSV_FILE")
          if [[ ! $ENCODING =~ "UTF-8" ]]
          then 
             $ICONV --from-code="$ENCODING" --to-code="UTF-8//TRANSLIT" --output="$GIRODIR/$WORKDIR/${CSV_NAME}.converted" "$CSV_FILE"
             mv "$GIRODIR/$WORKDIR/${CSV_NAME}.converted" "$CSV_FILE"    # write back converted file
          fi
          sed -i  -e 's/ä/ae/g' \
                  -e 's/ö/oe/g' \
                  -e 's/ü/ue/g' \
                  -e 's/Ä/AE/g' \
                  -e 's/Ö/OE/g' \
                  -e 's/Ü/UE/g' \
                  -e 's/ß/ss/g' "$CSV_FILE"
        done

 return $?
}
#----------------------------------------------------------------------------------------------------
# generate a cummulated csv of all giro-${KONTO}-????????-????????.camtv2.csv containing all data for the requested year ('-y YYYY')
#
function GENERATE_BASE_CSV () {
 local YEAR="$YEAR"   # global definiton
 local TYPE="$TYPE"   #       "
 local SIGN="$SIGN"   #       "
 local FSEP="$FSEP"   #       "

 [[ "$TYPE" == "eingang" ]] && SIGN="positiv"
 [[ "$TYPE" == "ausgang" ]] && SIGN="negativ"

 awk -v FSEP="$FSEP" -v YEAR="$YEAR" -v SIGN="$SIGN" '
BEGIN { FS  = FSEP
        YY  = substr(YEAR, length(YEAR)-1)
        VAL = SIGN                          # positiv | negativ | all ? 
        CNT = 0
        PAT = "^[0-3][0-9].[0-1][0-9].[0-9][0-9]$"  # regex pattern to check date fields (year **00-**99 allowed)
        DAT = "^[0-3][0-9].[0-1][0-9]." YY "$"      # regex pattern to check exactly requested year
        E_E = 0
        GPT = " *" FS " *"
      }

{
   if ($0 ~ /^#/)   {next}                       # skip commented records
   if ($0 ~ /^ *$/) {next}                       # skip empty records

   if (NF != 17) { print "error: required format CAMT-V2, found bad column/field count in file " FILENAME "\nrecord: " $0
                   E_E = 1
                   exit 1
                 }

   if ($17 ~ /Umsatz vorgemerkt/ || $0 ~ /^\s*$/) {next}    # unwanted record
   if ($1 ~ /"Auftragskonto"/) {next}            # skip evtl header line

   # some record tunings (required BEFORE next checks)
   gsub(/"/, "", $0)                             # remove all "
   gsub(/[[:space:]]+/, " ", $0)                 # squeeze whitespace 
   gsub(GPT, FS, $0)                             # "  ;  " => ";"
   gsub(/^[[:space:]]*|[[:space:]]*$/, "", $0)   # trim leading & trailing whitespace

   # $2 = Valuta Date pattern, eg '15.03.21'
   # first date field not of interesst!
   #if ($2 !~ PAT) { print "error: detected bad formatted date field #2: " $2 "\nfile: " FILENAME "\nrecord: " $0
   #                 E_E = 1
   #                 exit 1
   #               }

   # $3 = Valuta Date pattern, eg '15.03.21'
   if ($3 !~ PAT) { print "error: detected bad formatted date field #3 " $3 "\nfile: " FILENAME "\nrecord: " $0
                    E_E = 1
                    exit 1
                  }

   # $3 = Valuta Date pattern, eg '15.03.21'   
   if ($3 ~ DAT) { # obsolete! gsub(/[^\x20-\x7e,\xa0-\xff]/, "_", $0)  # replace non printable and non utf-8 chars !!! not required anymore because csv converted to UTF-8
                   gsub(/,/, ".", $15)                             # 22,34 => 22.34
                   if (VAL == "positiv" && $15  < 0) {next}        # skip negativ values
                   if (VAL == "negativ" && $15 >= 0) {next}        # skip positiv values (and '0')
                   if (VAL == "all")                 {}            # no action, just for syntax
                   # all ok, so try to unique append NEW record to array LIST
                   NEW = $3 FS $4 FS $5 FS $12 FS $13 FS $15
                   if (!unique[NEW]++) { LIST[CNT] = NEW; CNT++ }  # avoid doubled records
                 }
}

END { if (E_E) { exit 1 }
      for(CNT--; CNT >= 0; CNT--) {print LIST[CNT]}
      if (CNT == 0) { exit 1 }
    }
' $(eval ls -1 "$CSVPATT" | sort -t '-' -k 4 -r) > "$WORKDIR/$CSV_COMPLETE"
 # sorted by: giro-99999999-20211230-20230102.camtv2.csv
 #                                   ^^^^^^^^
 return $?
}
#----------------------------------------------------------------------------------------------------
# display CSV by search string
#
function DISPLAY_CSV () {
 local PATTERN="$1"

 [[ "$PATTERN" == "Umsatz_Eingang" ]] && PATTERN=".*"
 [[ "$PATTERN" == "Umsatz_Ausgang" ]] && PATTERN=".*"

 awk -v SEARCH="$PATTERN" '
BEGIN { FS  = ";"
        SUM = 0
        PAT = SEARCH
        CNT = 0
        IGNORECASE = 1
        printf("%s%s%s%s%s%s%s%s%s\n", "Datum", FS, "Buchungstext", FS, "Verwendungszweck", FS, "Korrespondent", FS, "Betrag")
      }

{
   if ($0 ~ PAT) {
      SUM += $6
      REC = $1 FS $2 FS $3 FS $4 FS $5 FS $6
      # gsub(/[^\x20-\x7e,\xa0-\xff]/, "_", REC)          # replace non printable and non utf-8 chars !!! not required anymore because csv converted to UTF-8
      if (!unique[REC]++) { LIST[CNT] = REC; CNT++ }      # make sure to avoid doubles
   }
}

END {
      # alternativ: for (IDX in LIST) { print LIST[IDX] }
      # ensure correct sequence:
      for (IDX = 0; IDX < CNT; IDX++) { 
            split(LIST[IDX], FLD, FS)
            printf("%s%s%s%s%s%s%s%s%s\n", FLD[1], FS, FLD[2], FS, FLD[3], FS, FLD[4], FS, FLD[6])
          }

      printf("%s%s%d%s%s%s%s%10.2f\n", "records", FS, CNT, FS, FS, "total (EUR)", FS, SUM)
      if (CNT == 0) { exit 1 }
    }
' < "$WORKDIR/$CSV_COMPLETE"
 return $?
}
#----------------------------------------------------------------------------------------------------
# display table by search string
#
function DISPLAY_TABLE () {
 local PATTERN="$1"

 [[ "$PATTERN" == "Umsatz_Eingang" ]] && PATTERN=".*"
 [[ "$PATTERN" == "Umsatz_Ausgang" ]] && PATTERN=".*"

 awk -v SEARCH="$PATTERN" '
BEGIN { FS  = ";"
        SUM = 0
        PAT = SEARCH
        CNT = 0
        IGNORECASE = 1
        printf("%-8s | %-25s | %-90s | %-65s | %10s\n\n", "Datum", "Buchungstext", "Verwendungszweck", "Korrespondent", "Betrag")
      }

{
   if ($0 ~ PAT) {
      SUM += $6
      REC = $1 FS $2 FS $3 FS $4 FS $5 FS $6
      # gsub(/[^\x20-\x7e]/, "_", REC)                   # replace non printable and non utf-8 chars !!! not required anymore because csv converted to UTF-8
      if (!unique[REC]++) { LIST[CNT] = REC; CNT++ }     # make sure to avoid doubles
   }
}

END {
      # alternativ: for (IDX in LIST) {
      # ensure correct sequence:
      for (IDX = 0; IDX < CNT; IDX++) {
            split(LIST[IDX], FLD, FS)
            printf("%8s | %-25s | %-90s | %-65s | %10.2f\n", FLD[1], substr(FLD[2],0,25), substr(FLD[3],0,90), substr(FLD[4],0,65), FLD[6])
          }
      printf("\n%-9s %-4d %182s %12.2f\n", "records:", CNT, "total (EUR):", SUM)
      if (CNT == 0) { exit 1 }
    }
' < "$WORKDIR/$CSV_COMPLETE"
 return $?
}
#----------------------------------------------------------------------------------------------------
function DISPLAY_UMSATZ () {
 local TITLE="$1"          # also leading part of output file name, no postfix, eg. .csv or .table etc
 local REGEX="$2"          # looking for ..?
 local SIGN="$SIGN"        # reflect positiv or negativ in filename
 local HEADER="$3"         # optional
 local YEAR="$YEAR"        # global definiton
 local PREFIX="$PREFIX"    # global definiton

 TITLE="${TITLE:=$PREFIX}" # if PREFIX != "" then change
 TITLE="${TITLE}-${YEAR}_${SIGN}"
 HEADER=${HEADER:=$TITLE}
 [[ "$PDF_HEADER" != "" ]] && HEADER="$PDF_HEADER"   # global PDF_HEADER by '-p' overwrites HEADER

 eval rm -f "$GIRODIR/$OUTDIR/$TITLE.*"   # pre cleanup

 printf ""             > "$GIRODIR/$OUTDIR/$TITLE.csv.tmp"
 DISPLAY_CSV "$REGEX" >> "$GIRODIR/$OUTDIR/$TITLE.csv.tmp" && { mv "$GIRODIR/$OUTDIR/$TITLE.csv.tmp" "$GIRODIR/$OUTDIR/$TITLE.csv"; } \
                                                           || { echo "info: no '$SIGN' records found in function DISPLAY_UMSATZ for title '$TITLE' (probably no csv data available?)"; rm -f "$GIRODIR/$OUTDIR/$TITLE.csv.tmp"; } 

 printf "$TITLE.table\n\n" > "$GIRODIR/$OUTDIR/$TITLE.table.tmp"
 DISPLAY_TABLE "$REGEX"   >> "$GIRODIR/$OUTDIR/$TITLE.table.tmp" && { mv "$GIRODIR/$OUTDIR/$TITLE.table.tmp" "$GIRODIR/$OUTDIR/$TITLE.table"; printf "\n\n"; cat "$GIRODIR/$OUTDIR/$TITLE.table"; } \
                                                                 || { rm -f "$GIRODIR/$OUTDIR/$TITLE.table.tmp"; }

 [ -e "$GIRODIR/$OUTDIR/$TITLE.table" ] && TABLE_TO_PDF "$GIRODIR/$OUTDIR/$TITLE.table" "$HEADER"
 return $?
}
#----------------------------------------------------------------------------------------------------
function SORT_BY_EURO () {
 local TITLE="$1"          # also part of output file name
 local LIMIT=$2
 local HEADER="$3"         # optional
 local SIGN="$SIGN"        # reflect positiv or negativ in filename
 local YEAR="$YEAR"        # global definiton
 local PREFIX="$PREFIX"    # global definiton

 TITLE="${TITLE:=$PREFIX}" # if PREFIX != "" then change
 TITLE="${TITLE}-${YEAR}_${SIGN}"
 HEADER=${HEADER:=$TITLE}
 [[ "$PDF_HEADER" != "" ]] && HEADER="$PDF_HEADER"   # global PDF_HEADER by '-p' overwrites HEADER

 eval rm -f "$GIRODIR/$OUTDIR/$TITLE.*"   # pre cleanup

 # sorted by EUR val field #6
 tr -d '"' < "$GIRODIR/$WORKDIR/$CSV_COMPLETE" \
           | sort -t ";" -k 6 -n \
           | awk -F ";" -v LIM="$LIMIT" '(sqrt(int($6)**2) >= LIM) {gsub(/[^\x20-\x7e]/, "_", $0); printf "%-9s | %-25s | %-90s | %-65s | %10.2f\n", $1, substr($2,0,25), substr($3,0,90), substr($4,0,65), $6}' \
           | tee "$GIRODIR/$OUTDIR/$TITLE.tmp" \
                 && { mv "$GIRODIR/$OUTDIR/$TITLE.tmp" "$GIRODIR/$OUTDIR/$TITLE.table"; printf "\n(no totals for this option)\n" >> "$GIRODIR/$OUTDIR/$TITLE.table"; cat "$GIRODIR/$OUTDIR/$TITLE.table"; } \
                                               || { echo "info: no records found in function SORT_BY_EURO, type '$TYPE'"; rm -f "$GIRODIR/$OUTDIR/$TITLE.tmp"; } 

 [ -e "$GIRODIR/$OUTDIR/$TITLE.table" ] && TABLE_TO_PDF "$GIRODIR/$OUTDIR/$TITLE.table" "$HEADER"

 return $?
}
#----------------------------------------------------------------------------------------------------
function DISPLAY_FILES () {
 local FILE="$1"
 local SIGN="$SIGN"        # reflect positiv or negativ in filename
 local YEAR="$YEAR"        # global definiton

 FILE="${FILE}*-${YEAR}_${SIGN}"

 printf "\ncreated files:\n"
 find "$GIRODIR/$OUTDIR/" -iname "$FILE.*" -ls | grep . || echo "info: no files created -> $GIRODIR/$OUTDIR/$FILE.*"
 return $?
}
#----------------------------------------------------------------------------------------------------
function TABLE_TO_PDF () {
 local TXTFILE="$1"                                # /bla/woops.table
 local PDFFILE="${TXTFILE%%.table}.pdf"            # /bla/woops.pdf
 local PDFNAME="$PDFFILE"
       PDFNAME=$(basename "$PDFNAME")              # woops.pdf
 local BASNAME=${PDFNAME%%.pdf}                    # woops

 local HEADER="$2"                                 # PDF_HEADER
       HEADER=${HEADER:=$BASNAME}
       HEADER=${HEADER:0:80}   # max 80 char

 local ENCODING
       ENCODING=$(file -b --mime-encoding "$TXTFILE")
       ENCODING=${ENCODING^^}

 local YEAR="$YEAR"

 local TODAY
       TODAY=$(date +'%Y-%m-%d')

 # convert between different character encodings
 if [ -e "$TXTFILE" ]
 then $ICONV --from-code="$ENCODING" --to-code="ISO88591//TRANSLIT" --output="$TXTFILE.tmp" "$TXTFILE"
 else echo "error: $ICONV could not find file '$TXTFILE'"
 fi

 # produce PDF from table file
 $ENSCRIPT --quiet --landscape --media="A4" --encoding="88591" --page-label-format="long" --header="$HEADER - $YEAR (print: $TODAY, p. $%/$=)" --font="Courier6" --non-printable-format="questionmark" "$TXTFILE.tmp" -o - \
           | ps2pdf - "$PDFFILE"

 rm -f "$TXTFILE.tmp"
 return $?
}
#----------------------------------------------------------------------------------------------------


#----------------------------------------------------------------------------------------------------
### MAIN
#----------------------------------------------------------------------------------------------------

# first convert csv files to usable mime type
MIME_CONVERT || { echo "error detected in function MIME_CONVERT, please check outfiles in $OUTDIR/ and $WORKDIR/"; exit 1; }

# create once the basic csv (no terminal output)
GENERATE_BASE_CSV || { echo "error detected in function GENERATE_BASE_CSV, please check outfiles in $OUTDIR/ and $WORKDIR/"; exit 1; }

printf "\noldest detected dataset in $GIRODIR/$WORKDIR/$CSV_COMPLETE\n"
head -1 "$GIRODIR/$WORKDIR/$CSV_COMPLETE"
echo ""

# what do you want to see ?
if [[ "$TYPE" =~ ^moos ]]
then
   
   PREFIX="${PREFIX:=Moosach}"
   DISPLAY_UMSATZ "${PREFIX}_Grundsteuer" "grundsteuer.*(oberwiesenfeld|moosach)" "Moosach/Oberwiesenfeld Grundsteuer"
   DISPLAY_UMSATZ "${PREFIX}_Hausgeld"    "hausgeld.*(oberwiesenfeld|moosach)"    "Moosach/Oberwiesenfeld Hausgeld"
   DISPLAY_UMSATZ "${PREFIX}_Miete"       "mietaussch.*(oberwiesenfeld|moosach)"  "Moosach/Oberwiesenfeld Miete"
   DISPLAY_UMSATZ "${PREFIX}_Sonstiges"   "Grundbuch.*Moosach|Sondereigentum.*145.*346.*136|moosach.*rate|MyApart.*(Moosach|Oberwiesenfeld)"  "Moosach/Oberwiesenfeld Sonstiges"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^unterf ]]
then
   PREFIX="${PREFIX:=Unterfoehring}"
   DISPLAY_UMSATZ "${PREFIX}_Grundsteuer" "grundsteuer.*unterfoehring" "Unterfoehring Grundsteuer"
   DISPLAY_UMSATZ "${PREFIX}_Hausgeld"    "hausgeld.*unterfoehring"    "Unterfoehring Hausgeld"
   DISPLAY_UMSATZ "${PREFIX}_Miete"       "mietaussch.*unterfoehring|pauschalierter Schadenersatz|Einheit A 5.24" "Unterfoehring Miete"
   DISPLAY_UMSATZ "${PREFIX}_Sonstiges"   "(UFH|Unterfoehring.*)Kaufpreisrate| 625222533706|Auflassung .*UFH|Terratax|Sondereigentum .*265.*736|MyApart Unterfoehring" "Unterfoehring Sonstiges"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^immo ]]
then
   PREFIX="${PREFIX:=Immobilien}"
   DISPLAY_UMSATZ "${PREFIX}_Grundsteuer"    "grundsteuer.*(oberwiesenfeld|moosach|unterfoehring)" "Immobilien Grundsteuer"
   DISPLAY_UMSATZ "${PREFIX}_Hausgeld"       "hausgeld.*(oberwiesenfeld|moosach|unterfoehring)"    "Immobilien Hausgeld"
   DISPLAY_UMSATZ "${PREFIX}_Miete"          "mietaussch.*(oberwiesenfeld|moosach|unterfoehring)|pauschalierter Schadenersatz|Einheit A 5.24" "Immobilien Mieteingang"
   DISPLAY_UMSATZ "${PREFIX}_Kaufpreisraten" "Kaufpreisraten|tilgung|abschlagszahlung|Moosach.*Rate|Unterfoehring.*Rate"  "Immobilien Kaufpreisraten"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^miete ]]
then
   PREFIX="${PREFIX:=Mieteingang}"
   DISPLAY_UMSATZ "${PREFIX}"  "mietaussch.*(oberwiesenfeld|moosach|unterfoehring)|pauschalierter Schadenersatz|Einheit A 5.24" "Immobilien Mieteingang"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^kaufpreis ]]
then
   PREFIX="${PREFIX:=Kaufpreisraten}"
   DISPLAY_UMSATZ "${PREFIX}"  "Kaufpreisraten|tilgung|abschlagszahlung|Moosach.*Rate|Unterfoehring.*Rate"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^versich ]]
then
   PREFIX="${PREFIX:=Versicherungen}"
   DISPLAY_UMSATZ "${PREFIX}"  "versicherung|generali|PRIVATSCHUTZ|Rechtsschutz|Landeskrankenhilfe|LKH"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" == "lohn" || "$TYPE" =~ ^gehalt ]]
then
   PREFIX="${PREFIX:=Gehalt}"
   DISPLAY_UMSATZ "${PREFIX}"  "lohn.*gehalt"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^rente ]]
then
   PREFIX="${PREFIX:=Rente}"
   DISPLAY_UMSATZ "${PREFIX}"  "97054030157S02311.*RV-RENTE.*Renten Service"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^pension ]]
then
   PREFIX="${PREFIX:=Pension}"
   DISPLAY_UMSATZ "${PREFIX}"  "Rente.*Pens.*05115455.*Siemens"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^einku ]]  # einkuenfte aus nicht-selbststaendiger Arbeit und nicht vermietung
then
   PREFIX="${PREFIX:=Einkuenfte}"
   DISPLAY_UMSATZ "${PREFIX}"  "lohn.*gehalt|97054030157S02311.*RV-RENTE.*Renten Service|Rente.*Pens.*05115455.*Siemens"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^steuer ]]
then
   PREFIX="${PREFIX:=Steuer}"
   DISPLAY_UMSATZ "${PREFIX}"  "117/269/90567|grundsteuer|steuer|finanzamt|finanzkasse|ekst|117/269/90567|1792699056719"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" == "depot" || "$TYPE" =~ ^wertpap ]]
then
   PREFIX="${PREFIX:=Depot}"
   DISPLAY_UMSATZ "${PREFIX}"  "WERTPAPIER|Depot |auxmoney|Anlegerauszahlung|Depotgebuehren|Wertp.Abrechn."
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" == "erbe" || "$TYPE" =~ ^schenkung ]]
then
   PREFIX="${PREFIX:=Erbe}"
   DISPLAY_UMSATZ "${PREFIX}"  " erbe |erbschaft|schenkung"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" =~ ^arzt || "$TYPE" =~ ^medizin ]]
then
   PREFIX="${PREFIX:=Medizin}"
   DISPLAY_UMSATZ "${PREFIX}"  "dr. |labor|medizin|apotheke|untersuchung|arzt"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" == "eingang" ]]
then
   PREFIX="${PREFIX:=Umsatz_Eingang}"
   DISPLAY_UMSATZ "${PREFIX}" "Umsatz_Eingang"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" == "ausgang" ]]
then
   PREFIX="${PREFIX:=Umsatz_Ausgang}"
   DISPLAY_UMSATZ "${PREFIX}" "Umsatz_Ausgang"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" == "total" ]]
then
   PREFIX="${PREFIX:=Total}"
   DISPLAY_UMSATZ "${PREFIX}" ".*"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "${TYPE%%:*}" == "search" ]]
then
   PREFIX="${PREFIX:=Search}"
   REGEX="${TYPE#*:}"
   DISPLAY_UMSATZ "${PREFIX}"  "$REGEX"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" == "large" ]]
then
   PREFIX="${PREFIX:=Large}"
   SORT_BY_EURO   "${PREFIX}" "$LIMIT"
   DISPLAY_FILES  "${PREFIX}"

elif [[ "$TYPE" == "complete" ]]
then
   for TYPE in moosach unterfoehring kaufpreisrate rente pension gehalt versicherung steuer medizin depot eingang ausgang
   do
     printf "\n********** calculating $TYPE **********\n"
     $0 -y "$YEAR" -t "$TYPE"
   done

else
   echo "error: unknown TYPE \$1 '$TYPE'"
   exit 1
fi


#----------------------------------------------------------------------------------------------------
printf "\n"
exit $?
#----------------------------------------------------------------------------------------------------

