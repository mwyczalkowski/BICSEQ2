#!/bin/bash

conda create -n bicseq2
conda install -c conda-forge parallel -n bicseq2
conda install -c r r -n bicseq2
conda install -c bioconda bedtools -n bicseq2
conda install -c conda-forge numpy -n bicseq2