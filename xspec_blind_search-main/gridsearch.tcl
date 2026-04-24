#########################################################################################
# STEP 1: SETUP - LOADING THE CONTENTS OF SETUP.TXT
#########################################################################################
# Opening the setup file:
set setup [open "setup.txt" r]
set setupcontents [read $setup]
close $setup

# splitting the setup contents and creating an empty list:
set setupinfo [split $setupcontents "\n"]
set setup_list [list ]

# going through each line in the setup file, check if it starts with # - if not, add it to
# the empty list:
foreach line $setupinfo {
set fl [string index $line 0]
if {$fl == "#"} {
} else {
lappend setup_list $line}
}

# setting the parameters of the search to the correct value in the list:
set source [lindex $setup_list 0]
set instrument [lindex $setup_list 1]
set obsid [lindex $setup_list 2]
set binning [lindex $setup_list 3]
set modeltype [lindex $setup_list 4]
set cstat [lindex $setup_list 5]
set freezecontinuum [lindex $setup_list 6]
set fitcontinuum [lindex $setup_list 7]
set saveplots [lindex $setup_list 8]
set Lmin [lindex $setup_list 9]
set Lmax [lindex $setup_list 10]
set dL [lindex $setup_list 11]
set velocitywidth [lindex $setup_list 12]
set continuum [lindex $setup_list 13]
set linemodel [lindex $setup_list 14]
set numpars [lindex $setup_list 15]
set spectra_list [list ]
for {set i 16} {$i < [llength $setup_list] - 1} {incr i} {
lappend spectra_list [lindex $setup_list $i]
}

# setting basic fitting statistic: cstat or chi2
# Note: in tcl, there are no booleans (e.g. True of False). Instead, 0 = false, 1 (or any integer > 0) = true.
#set cstat 1
if {$cstat} {
set chi2 0
set fitstat "cstat"} else {
set chi2 1
set fitstat "chi2"}

# Defining the energy grid (not wavelength - the input of Gauss is in energy):
set conversionfactor 12.39841975
set Emin [format "%0.8e" [expr {$conversionfactor / $Lmax}]] 
set Emax [format "%0.8e" [expr {$conversionfactor / $Lmin}]] 
set speedoflight 299792.458

# Defining the wavelength range for fitting: not necessarily the same as the grid: (Chandra: Lhigh=18)
set Llow $Lmin
set Lhigh $Lmax

# determining the amount of provided spectra:
set n_spectra [llength $spectra_list]

# Setting up the parameter values and parameter numbers for the Gaussian line
set gaussianenergy $Emin
set gaussianwidth 0.001
set gaussiannorm 0.0001
set Ngaussianenergy [expr {$numpars - 2}]
set Ngaussianwidth [expr {$numpars - 1}]
set Ngaussiannorm $numpars

# Set some XSpec defaults
query yes
xsect vern
abun wilm
weight churazov
# Use the following command to parallelize the fit command: (xpc19 and xpc1 both have 4 cores; my MacBook has 2.)
parallel leven 2

# setting the root for all filenames, and making the folder if it doesn't exist yet:
set fileroot "./output/"
append fileroot $source "/"
mkdir $fileroot
append fileroot $obsid "/"
mkdir $fileroot


# setting the filename for the .dat file:
if {$freezecontinuum} {
set frozen "froz"} else {
set frozen "free"}
if {$fitcontinuum} {
set fitted "fit"} else {
set fitted "nofit"}
set min [format "%0.0f" $Lmin]
set max [format "%0.0f" $Lmax]
set res [format "%0.0e" $dL]
set vel [format "%0.0f" $velocitywidth]

set dat_file $fileroot
append dat_file $frozen "_" $fitted "_" $fitstat "_" $min "_" $max "_" $res "_" $vel "kms_" $binning "_" $modeltype ".dat"

#########################################################################################
# STEP 2: SETTING UP THE CONTINUUM
#########################################################################################
# Loading the spectrum:
set i 0
while {$i < $n_spectra} {
set j [expr $i+1]
data $j:$j [lindex $spectra_list $i]
incr i
}

# Setting the gain parameter if you want:
gain 1:1 1.0 8.942e-4

# noticing the correct energy range:
setpl wave
ig bad
if {$n_spectra > 1} {
ig 1-$n_spectra: **-**
notice 1-$n_spectra: $Llow-$Lhigh } else {
ig **-**
notice $Llow-$Lhigh}

# noticing another range in the second loaded spectrum if the instrument is RGS, two spectra are loaded and the upper limit of the wavelength range exceeds 18.5 Angstrom:
set RGS_maxA 16.0
set RGS_minA 7.0
if {$instrument == "RGS"} {
if {$n_spectra == 2} {
if {$Lhigh > $RGS_maxA} {
ig 2: **-**
notice 2: $RGS_minA - $RGS_maxA
} } }

set paramfile [open $dat_file w]
puts $paramfile "\# Source: $source"
puts $paramfile "\# Instrument: $instrument"
puts $paramfile "\# ObsID: $obsid"
puts $paramfile "\#"
puts $paramfile "\# Spectrum: $spectra_list"
puts $paramfile "\# Continuum model: $continuum"
puts $paramfile "\# Full line model: $linemodel"
puts $paramfile "\# Minimum wavelength of search grid: $Lmin"
puts $paramfile "\# Maximum wavelength of search grid: $Lmax"
puts $paramfile "\# Size of wavelength steps in search grid: $dL"
puts $paramfile "\# Velocity width of lines in km/s: $velocitywidth"
puts $paramfile "\# Fit Statistic: $fitstat"
puts $paramfile "\# ######################################################################################################"
puts $paramfile "\# Gridpoint Normalisation       MinError        PlusError       Fit-Stat    DoF     D-Fit-Stat  D-DoF  #"
puts $paramfile "\# ######################################################################################################"

# Loading the continuum model:
$continuum
# Fitting the continuum model to calculate the fit statistic:
if {$fitcontinuum} {
fit 1000}

# Saving the fit statistic - this will not be written to the parameter file, but we'll need it to calculate its change:
tclout stat
set contfitstat [string trim $xspec_tclout]
regsub -all { +} $contfitstat { } ccontfitstat
set lcontfitstat [split $ccontfitstat]
set continuumfitstatistic [format "%0.5f" [lindex $lcontfitstat 0]]

# Freezing all parameters in the continuum model, if wanted:
if {$freezecontinuum} {
freeze *-*}

# After possibly freezing the continuum, saving the number of degrees of freedom before adding the narrow line:
tclout dof
set contdeg [string trim $xspec_tclout]
regsub -all { +} $contdeg { } ccontdeg
set lcontdeg [split $ccontdeg]
set continuumdegreesoffreedom [lindex $lcontdeg 0]

# Making an image of the continuum fit, and a seperate one of the ratio fit
if {$saveplots} {
setplot add
setplot command "la t $linemodel"
setplot command "font roman"
setplot command "time off"
setplot command "csize 0.8"
setplot command "lwidth 3"
setplot command "color 2 on 2 3"
setplot command "li st"
setplot command "log x off"
setplot command "r x $Lmin $Lmax"
setplot command "r y 3e-20 5e-18"
setplot device output/continuum.ps/cps
plot ld
setplot device /xw
plot ld

setplot command "r y 0.5 2.0"
setplot device output/ratio.ps/cps
plot ratio
setplot device /xw
plot ratio}

####################################################################################
# STEP 3: SEARCHING FOR NARROW GAUSSIAN LINES
####################################################################################

# Adding the Gaussian component at the minimum energy of the grid:
editmod $linemodel
# Setting the parameters to the defined initial guesses:
$gaussianenergy
$gaussianwidth
$gaussiannorm
# Freezing the energy and normalisation of the line:
freeze $Ngaussianenergy
freeze $Ngaussianwidth

newpar $Ngaussiannorm $gaussiannorm 0.00000001 -1. -1. 1. 1.

# Defining a new parameter representing the Gaussian centroid, that can be updated:
set updatedgaussianenergy $gaussianenergy

# Loop over the energy grid, untill the Gaussian line centroid becomes larger than or equal to the maximum energy:
while { $updatedgaussianenergy < $Emax } {

# set the Gaussian width to the correct value in keV that corresponds to the required one in velocity
set Lequivalent [format "%0.8e" [expr {$conversionfactor / $updatedgaussianenergy}]]
set gaussianwidthE [format "%0.5f" [expr {($velocitywidth / $speedoflight) * $updatedgaussianenergy}]]
newpar $Ngaussianwidth $gaussianwidthE

# Fit: with a check to prevent the code from stopping if the fit does not converge:
if { [catch fit 1000] } {
# if for whatever reason the fit does not work: write out a zero normalisation:
set normalisation 0.0
set fitstatistic $continuumfitstatistic
set degreesoffreedom [expr {$continuumdegreesoffreedom - 1}] } else {
# if it doesn't go wrong (by far most often), actually perform the fit:
fit 1000

# Saving the normalisation:
tclout param $Ngaussiannorm
set norm2 [string trim $xspec_tclout]
regsub -all { +} $norm2 { } cnorm2
set lnorm2 [split $cnorm2]
set normalisation [format "%0.8e" [lindex $lnorm2 0]]

# Saving the fit statistic:
tclout stat
set fitstat [string trim $xspec_tclout]
regsub -all { +} $fitstat { } cfitstat
set lfitstat [split $cfitstat]
set fitstatistic [format "%0.5f" [lindex $lfitstat 0]]

# Saving the number of degrees of freedom:
tclout dof
set deg [string trim $xspec_tclout]
regsub -all { +} $deg { } cdeg
set ldeg [split $cdeg]
set degreesoffreedom [lindex $ldeg 0]
}

# calculating the error on the line normalisation:
err 1. $Ngaussiannorm
tclout error $Ngaussiannorm
set errnorm [string trim $xspec_tclout]
regsub -all { +} $errnorm { } cerrnorm
set lerrnorm [split $cerrnorm]
set errnorml [lindex $lerrnorm 0]
set errnormh [lindex $lerrnorm 1]
set normerrormin [format "%0.8e" [expr {$normalisation-$errnorml}]]
set normerrorplus [format "%0.8e" [expr {$errnormh-$normalisation}]]

# calculating the difference in fit statistic and d.o.f.s compared to the continuum fit:
set deltastat [format "%0.5f" [expr {$continuumfitstatistic - $fitstatistic}]]
set deltadof [expr {$continuumdegreesoffreedom - $degreesoffreedom}]

# Writing the parameters to the file:
puts -nonewline $paramfile "$updatedgaussianenergy \t"  
puts -nonewline $paramfile "$normalisation \t"
puts -nonewline $paramfile "$normerrormin \t"
puts -nonewline $paramfile "$normerrorplus \t"
puts -nonewline $paramfile "$fitstatistic \t"
puts -nonewline $paramfile "$degreesoffreedom \t"
puts -nonewline $paramfile "$deltastat \t"
puts -nonewline $paramfile "$deltadof \n" 

# Increasing the gaussian centroid energy:
set Lnew [format "%0.8e" [expr {$Lequivalent - $dL}]]
set updatedgaussianenergy [format "%0.8e" [expr {$conversionfactor / $Lnew}]]
#set updatedgaussianenergy [format "%0.8e" [expr {$gaussianenergy + $i * $deltaE}]]
newpar $Ngaussianenergy $updatedgaussianenergy

# Setting the Gaussian norm to the initial estimate: not doing this might lead to a situation where it pegs at a very low level if
# there is not line, such that the fit is insensitive to this parameter. That will result in either no free params (if the continuum
# is frozen) or an incorrect fit for the normalisation. In both cases, the result is inaccurate.
newpar $Ngaussiannorm $gaussiannorm
}

close $paramfile
# Moving the data to the ./backup/source/obsid folder:
set cwd "."
mkdir [append cwd "/data_backups/" $source]
mkdir [append cwd "/" $obsid]
set i 0
while {$i < $n_spectra} {
set spectrum [lindex $spectra_list $i]
set len [string length $spectrum]
set spectrumroot [string replace $spectrum [format "%0.0f" [expr $len - 16.0]] [format "%0.0f" [expr $len - 1.0]]]
mv [append spectrumroot "*"] $cwd
incr i
}
# Quit XSpec
quit
