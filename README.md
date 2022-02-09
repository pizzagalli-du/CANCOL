# CANCOL
a Computer-Assisted Annotation Tool to Facilitate Colocalization and Tracking of Immune Cells in Intravital Microscopy

...Especially when there is channel crosstalking, high background, poor fluoophore-cell specificity, or cells become dim.

And can also be applied to improve the visibiity of other structures (i.e. vessels) and facilitate their 3d reconstruction.

In press at The Journal of Immunology (Expected release March 2022)

## INSTALLATION
If you have Matlab installed
1. Dowload and copy the content of this repository it in the XTension matlab folder of Imaris (i.e. C:\Program Files\Bitplane\Imaris x64 9.7.2\XT\matlab)

If you do not have Matlab
1. Install the free Matlab runtimes from https://ch.mathworks.com/products/compiler/matlab-runtime.html
2. Download and copy the content of this repository in the XTension rtmatlab folder of Imaris
(i.e. C:\Program Files\Bitplane\Imaris x64 9.7.2\XT\rtmatlab)

## HOW TO USE
CANCOL is available as a plugin for IMARIS
Once installed, it can be launched from the menu bar of imaris, under IRB 2-photon toolbox.
- XTPixelClassification_SVM is a slim version of the program with the old user interface that saves RAM but does not provide user assistance.
- XTCANCOL employs a new user interface to support the user during the annotation process.

The standalone version CANCOL_standalone instead can be launched without Imaris installed.

## Examples
![Resulting virtual channel specific for the cells of interest color-coded in magenta](/assets/examples_coloc.png)
