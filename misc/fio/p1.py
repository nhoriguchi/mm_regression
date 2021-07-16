import matplotlib as mpl
mpl.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import csv
import sys
import json

datadict = {}

def getdatafile(cpu, pltype):
    if pltype == "aio":
        return "./work/210714_fio3/pmem/fsdax/fio.auto3/1-1/cpu-%d/fsdax_%s.json" % (cpu, pltype)
        return "./data/pmem/fsdax/fio.auto3/1-1/cpu-%d/fsdax_%s.json" % (cpu, pltype)
    elif pltype == "dev-dax":
        return "./work/210714_fio7/pmem/fio.auto3/1-1/cpu-%d/%s.json" % (cpu, pltype)
    else:
        return "./work/210714_fio6/pmem/fio.auto3/1-1/cpu-%d/%s.json" % (cpu, pltype)
        return "./data/pmem/fsdax/fio.auto3/1-1/cpu-%d/fsdax_%s.json" % (cpu, pltype)

cpus = [1, 2, 4, 8, 16, 32, 64]
pltypes = ["mmap", "syswrite", "aio"]

# work/210714_fio6/pmem/fio.auto3/1-1/cpu-2/pmemblk.json
pltypes = ["pmemblk", "libpmem", "dev-dax"]

for cpu in cpus:
    for pltype in pltypes:
        key = "%d-fsdax_%s" % (cpu, pltype)
        datafile = getdatafile(cpu, pltype)
        datadict[key] = {}
        tmp = json.load(open(datafile, 'r'))
        datadict[key]["global options"] = tmp["global options"]
        datadict[key]["jobs"] = {}
        for j in tmp["jobs"]:
            datadict[key]["jobs"][j["jobname"]] = j

# print(datadict.keys())
# print(datadict["1-fsdax_mmap"]["global options"])
# print(datadict["1-fsdax_mmap"]["jobs"].keys())

def plotA(pltype):
    plotdata = []
    plotdataerr = []
    randreads = []
    randwrites = []
    seqreads = []
    seqwrites = []
    randreadserr = []
    randwriteserr = []
    seqreadserr = []
    seqwriteserr = []

    for i in cpus:
        label = "%d-fsdax_%s" % (i, pltype)
        rrbw_mean = round(datadict[label]["jobs"]["randread"]["read"]["bw_mean"]   / 1024) / 1024.0
        rrbw_dev  = round(datadict[label]["jobs"]["randread"]["read"]["bw_dev"]    / 1024) / 1024.0
        rwbw_mean = round(datadict[label]["jobs"]["randwrite"]["write"]["bw_mean"] / 1024) / 1024.0
        rwbw_dev  = round(datadict[label]["jobs"]["randwrite"]["write"]["bw_dev"]  / 1024) / 1024.0
        srbw_mean = round(datadict[label]["jobs"]["seqread"]["read"]["bw_mean"]    / 1024) / 1024.0
        srbw_dev  = round(datadict[label]["jobs"]["seqread"]["read"]["bw_dev"]     / 1024) / 1024.0
        swbw_mean = round(datadict[label]["jobs"]["seqwrite"]["write"]["bw_mean"]  / 1024) / 1024.0
        swbw_dev  = round(datadict[label]["jobs"]["seqwrite"]["write"]["bw_dev"]   / 1024) / 1024.0
        randreads.append(rrbw_mean)
        randwrites.append(rwbw_mean)
        seqreads.append(srbw_mean)
        seqwrites.append(swbw_mean)
        randreadserr.append(rrbw_dev)
        randwriteserr.append(rwbw_dev)
        seqreadserr.append(srbw_dev)
        seqwriteserr.append(swbw_dev)
        plotdata.append([rrbw_mean, rwbw_mean, srbw_mean, swbw_mean])
        plotdataerr.append([rrbw_dev, rwbw_dev, srbw_dev, swbw_dev])

    plotdata2 = pd.DataFrame({"RandRead": randreads, "RandWrite": randwrites, "SeqRead": seqreads, "SeqWrite":seqwrites}, index=cpus)
    bar = plotdata2.plot.bar(rot=0, yerr={"RandRead": randreadserr, "RandWrite": randwriteserr, "SeqRead": seqreadserr, "SeqWrite":seqwriteserr})
    bar.set_xlabel('NumJobs')
    bar.set_ylabel('Throughput (GiB/s)')
    bar.set_ylim(0, ymax)
    # bar.set_title(plottitle)
    fig = bar.get_figure()
    fig.savefig("/tmp/fio/figure-%s.png" % pltype)

def plotB(pltype):
    plotdata = []
    plotdataerr = []
    randreads = []
    randwrites = []
    randreadserr = []
    randwriteserr = []

    for i in cpus:
        label = "%d-fsdax_%s" % (i, pltype)
        rrbw_mean = round(datadict[label]["jobs"]["randread"]["read"]["bw_mean"]   / 1024) / 1024.0
        rrbw_dev  = round(datadict[label]["jobs"]["randread"]["read"]["bw_dev"]    / 1024) / 1024.0
        rwbw_mean = round(datadict[label]["jobs"]["randwrite"]["write"]["bw_mean"] / 1024) / 1024.0
        rwbw_dev  = round(datadict[label]["jobs"]["randwrite"]["write"]["bw_dev"]  / 1024) / 1024.0
        randreads.append(rrbw_mean)
        randwrites.append(rwbw_mean)
        randreadserr.append(rrbw_dev)
        randwriteserr.append(rwbw_dev)
        plotdata.append([rrbw_mean, rwbw_mean])
        plotdataerr.append([rrbw_dev, rwbw_dev])

    plotdata2 = pd.DataFrame({"RandRead": randreads, "RandWrite": randwrites}, index=cpus)
    bar = plotdata2.plot.bar(rot=0, yerr={"RandRead": randreadserr, "RandWrite": randwriteserr})
    bar.set_xlabel('NumJobs')
    bar.set_ylabel('Throughput (GiB/s)')
    bar.set_ylim(0, ymax)
    # bar.set_title(plottitle)
    fig = bar.get_figure()
    fig.savefig("/tmp/fio/figure-%s.png" % pltype)

ymax = 35
for pltype in pltypes:
    if pltype == "pmemblk":
        plotB(pltype)
    else:
        plotA(pltype)
