import numpy as np
import matplotlib.pyplot as plt
import scipy.stats as stats
from decimal import Decimal
import os

##########################################################################################################
# Loading the data:
##########################################################################################################
setup_file = './setup.txt'
setup_info = np.genfromtxt(setup_file, dtype=str, comments='#', delimiter='\t')
paramfileroot = './output/'+setup_info[0]+'/'+setup_info[2]+'/' 

if setup_info[6] == '1':
    frozen = "froz"
else:
    frozen = "free"
if setup_info[7] == '1':
    fitted = 'fit'
else:
    fitted = 'nofit'
Min = setup_info[9].split('.',100)[0]
Max = setup_info[10].split('.',100)[0]
res = "{:.0E}".format(Decimal(setup_info[11]))[0] + 'e-' + '0' + "{:.0E}".format(Decimal(setup_info[11]))[-1]
vel = setup_info[12].split('.',100)[0]
binning = setup_info[3]
modeltype = setup_info[4]

cstat_paramfile = paramfileroot + frozen + '_' + fitted + '_cstat_' + Min + '_' + Max + '_' + res + '_' + vel  + 'kms_' + binning  + '_' + modeltype + '.dat'
while not os.path.exists(cstat_paramfile) and not cstat_paramfile.lower() == 'abort':
    print('')
    print('cstat parameter file not found')
    print('Attempted filename: '+cstat_paramfile)
    print('Provide new input filename manually, or type abort:')
    cstat_paramfile = str(raw_input('Manual input: '))
cstat_params = np.loadtxt(cstat_paramfile, usecols=None, unpack=True)

chi2data = False
if os.path.exists(paramfileroot + frozen + '_' + fitted + '_chi2_' + Min + '_' + Max + '_' + res + '_' + vel  + 'kms_' + binning  + '_' + modeltype + '.dat'):
    chi2_paramfile = paramfileroot + frozen + '_' + fitted + '_chi2_' + Min + '_' + Max + '_' + res + '_' + vel  + 'kms_' + binning  + '_' + modeltype + '.dat' 
    chi2_params = np.loadtxt(chi2_paramfile, usecols=None, unpack=True)
    #chi2data = True
else:
    print('')
    print('chi2 parameter file not found')

##########################################################################################################
# converting the energy grid to a wavelength grid:
##########################################################################################################
conversionfactor = 12.39841975
energy_grid = cstat_params[0]
wavelength_grid = conversionfactor/energy_grid
#print energy_grid

##########################################################################################################
# dividing the loaded data into the seperate parameters:
##########################################################################################################
normalisations = cstat_params[1]
norm_err_min = cstat_params[2]
norm_err_plus = cstat_params[3]
delta_cstat = cstat_params[6]
if chi2data:
    delta_chi2 = chi2_params[6]

##########################################################################################################
# Determining the error on the normalisation, dealing with possibly assymetric errors:
##########################################################################################################
error_method_norm = 'mean' # alternatively: max, min.
norm_err = []
for i in xrange(len(normalisations)):
    if norm_err_min[i] != 0. and norm_err_min[i] != normalisations[i] and norm_err_plus[i] != -1*normalisations[i]:
        if error_method_norm == 'mean':
            norm_err.append((norm_err_min[i]+norm_err_plus[i])/2.)
        elif error_method_norm == 'max':
            norm_err.append(max([norm_err_min[i], norm_err_plus[i]]))
        elif error_method_norm == 'min':
            norm_err.append(min([norm_err_min[i], norm_err_plus[i]]))
        else:
            print 'Unknown method to determine normalisation error...'
    elif norm_err_min[i] == normalisations[i]:
        norm_err.append(norm_err_plus[i])
    elif norm_err_plus[i] == -1*normalisations[i]:
        norm_err.append(norm_err_min[i])
    else:
        norm_err.append(1e30)
norm_err = np.asarray(norm_err)

##########################################################################################################
# Calculation of the Dchi2 value corresponding to 1,2,3,4,5 sigma levels, given the initial chi2 and the number of degrees of freedom:
# one-sided!!!
##########################################################################################################
if chi2data:
    xsigma_p = [0.682689492137086, 0.954499736103642, 0.997300203936740, 0.999936657516334, 0.999999426696856] #1,2,3,4,5 sigma level
    dof1 = 1.
    dof2 = chi2_params[5][0]
    chi2_voor = chi2_params[4][0]+chi2_params[6][0]
    xsigma_dchi2 = []
    for p in xsigma_p:
        Fmin = stats.f.isf(1.0-p, dfn=dof1, dfd=dof2)
        dchi2_min = (Fmin*chi2_voor)/(dof2+Fmin)
        xsigma_dchi2.append(dchi2_min)
    
##########################################################################################################        
# Calculating the line energies of significant (> 3 sigma) lines:
##########################################################################################################
print '======================================================='
print 'Significance first dataset'
print 'Wav [Ang] \tEnergy [keV] \tSignificance \tEm/Ab'
print '======================================================='
sigs = np.asarray(normalisations)/np.asarray(norm_err)
for i in xrange(2, len(sigs)-2):
    if abs(sigs[i]) >= 3. and abs(sigs[i]) > abs(sigs[i-1]) and abs(sigs[i]) > abs(sigs[i-2]) and abs(sigs[i]) > abs(sigs[i+1]) and abs(sigs[i]) > abs(sigs[i+2]):
    #if abs(sigs[i]) >= 2. and abs(sigs[i]) < 3.0 and abs(sigs[i]) > abs(sigs[i-1]) and abs(sigs[i]) > abs(sigs[i-2]) and abs(sigs[i]) > abs(sigs[i+1]) and abs(sigs[i]) > abs(sigs[i+2]):
        print_string = str(np.round(wavelength_grid[i],2)) + '\t \t' + str(np.round(conversionfactor/wavelength_grid[i], 2)) + '\t \t' + str(np.round(abs(sigs[i]),2)) + '\t\t' #+ str(normalisations[i]) + '\t' + str(energy_grid[i]) + '\t'
        if sigs[i] > 0:
            print_string = print_string + 'emission'
        else:
            print_string = print_string + 'absorption'
        print print_string
print '======================================================='

##########################################################################################################        
# Defining the figure and axes:
##########################################################################################################
fig = plt.figure(figsize=(12,9))
#ax1 = fig.add_subplot(311)
#ax2 = fig.add_subplot(312)
#ax3 = fig.add_subplot(313)
ax1 = fig.add_subplot(211)
ax3 = fig.add_subplot(212)

##########################################################################################################
# Setting labels:
##########################################################################################################
min_wav = int(np.floor(float(setup_info[9])))
max_wav = int(np.ceil(float(setup_info[10])))

ax1.set_ylabel(r'$\Delta C$', fontsize=20)
#ax2.set_ylabel(r'$\Delta \chi^2$', fontsize=20)
ax3.set_ylabel(r'$\rm N_{\rm line}/\sigma_{\rm N}$', fontsize=20)
ax3.set_xlabel(r'$\rm Wavelength$ $\rm [\AA]$', fontsize=20)

ax1.set_xticklabels([])
ax1.set_xticks(list(np.linspace(min_wav, max_wav, max_wav-min_wav+1)))
ax3.set_xticks(list(np.linspace(min_wav, max_wav, max_wav-min_wav+1)))

if min_wav == 6.0 and max_wav == 30:
    ax3.set_xticklabels(['', r'$7$', '', '', r'$10$', '', '', '', '', r'$15$', '', '', '', '', r'$20$', '', '', '', '', r'$25$', '', '', '', '', r'$30$'])

##########################################################################################################
# Setting basic plot parameters:
##########################################################################################################
MS=4
LW=1.5 #0.75
LW2=1.5
C='b'
C2='m'
# Defining x-axis:
x_axis = wavelength_grid

##########################################################################################################
# Plotting significance levels:
##########################################################################################################
ax1.plot([min(x_axis), max(x_axis)], [9., 9.], 'k-.', lw=1)
if chi2data:
    ax2.plot([min(x_axis), max(x_axis)], [xsigma_dchi2[2], xsigma_dchi2[2]], 'k--', lw=1, label=r'$3\sigma$')
    ax2.plot([min(x_axis), max(x_axis)], [xsigma_dchi2[3], xsigma_dchi2[3]], 'k-.', lw=1, label=r'$4\sigma$')
    ax2.plot([min(x_axis), max(x_axis)], [xsigma_dchi2[4], xsigma_dchi2[4]], 'k:', lw=1, label=r'$5\sigma$')
    ax2.legend(loc='best', fontsize=12, frameon=True)
#ax3.plot([min(x_axis), max(x_axis)], [3., 3.], 'b--', lw=1, label=r'$3\sigma$')
ax3.plot([min(x_axis), max(x_axis)], [4., 4.], 'k-.', lw=1, label=r'$4\sigma$')
ax3.plot([min(x_axis), max(x_axis)], [5., 5.], 'k:', lw=1, label=r'$5\sigma$')
#ax3.plot([min(x_axis), max(x_axis)], [-3., -3.], 'b--', lw=1)
ax3.plot([min(x_axis), max(x_axis)], [-4., -4.], 'k-.', lw=1)
ax3.plot([min(x_axis), max(x_axis)], [-5., -5.], 'k:', lw=1)
#ax3.legend(loc='best', fontsize=12, frameon=True)
ax3.fill_between([min(x_axis), max(x_axis)], [-2., -2.], [2., 2.], facecolor='0.50', interpolate=True)
ax3.fill_between([min(x_axis), max(x_axis)], [-3., -3.], [-2., -2.], facecolor='0.80', interpolate=True)
ax3.fill_between([min(x_axis), max(x_axis)], [2., 2.], [3., 3.], facecolor='0.80', interpolate=True)
ax3.plot([min(x_axis), max(x_axis)], [0., 0.], 'c-', lw=2)

##########################################################################################################
# Plotting data:
##########################################################################################################

ax1.plot(x_axis, delta_cstat, '-', lw=LW, color=C)
if chi2data:
    ax2.plot(x_axis, delta_chi2, '-', lw=LW, color=C)
ax3.plot(x_axis, normalisations/norm_err, '-', lw=LW, color=C)

for ax in [ax1, ax3]:#, ax2]:
    ax.tick_params(labelsize=16, width=2, length=8, axis='both', which='major', pad=8)
    ax.tick_params(labelsize=16, length=5, width=2, axis='both', which='minor', pad=8)
    ax.set_xlim((min_wav, max_wav))	

else:
    max_y1 = max([10, max(delta_cstat)*1.1])
    if chi2data:
        max_y2 = max(delta_chi2)*1.1
    max_y3 = max([5., max(normalisations/norm_err)*1.1])
    min_y3 = min([-5., min(normalisations/norm_err)*1.1])
ax1.set_ylim((0., max_y1))
if chi2data:
    ax2.set_ylim((0., max_y2))
#ax3.set_ylim((min_y3, max_y3))
#ax3.set_ylim((-5.0, 5.0))

plt.tight_layout()
#plt.show()
if chi2data:
    plt.savefig(paramfileroot + frozen + '_' + fitted + '_both_' + Min + '_' + Max + '_' + res + '_' + vel  + 'kms_' + binning  + '_' + modeltype + '.pdf')
    print "Saved "+paramfileroot + frozen + '_' + fitted + '_both_' + Min + '_' + Max + '_' + res + '_' + vel  + 'kms_' + binning  + '_' + modeltype + '.pdf'
else:
    plt.savefig(paramfileroot + frozen + '_' + fitted + '_cstat_' + Min + '_' + Max + '_' + res + '_' + vel  + 'kms_' + binning  + '_' + modeltype + '.pdf')
    print "Saved "+paramfileroot + frozen + '_' + fitted + '_cstat_' + Min + '_' + Max + '_' + res + '_' + vel  + 'kms_' + binning  + '_' + modeltype + '.pdf'



