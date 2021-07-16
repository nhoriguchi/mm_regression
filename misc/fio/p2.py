import matplotlib as mpl
mpl.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import csv
import sys
import json
import os

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

def getdatafile(projname, recipename, cpu, bsize, plottype):
    return "./work/%s/pmem/%s/1-1/c%d_bs%s/%s.json" % (projname, plottype[0], cpu, bsize, plottype[1])

def getkey(cpu, bsize, plottype):
    return "%s_c%d_bs%s_%s" % (plottype[0], cpu, bsize, plottype[1])

cpus = [1, 2, 4, 8, 16, 32, 64]
pltypes = ["pmemblk", "libpmem", "dev-dax"]

projname = "210714_fio8"
cpus = [1, 2, 4, 8, 16, 32]
bsizes = ["4k", "2m"]
recipenames = [
    "fio_type-fsdax.auto3",
    "fio_type-pmemblk.auto3",
    "fio_type-dev-dax.auto3",
    "fio_type-libpmem_nt-false_sync-false.auto3",
    "fio_type-libpmem_nt-false_sync-true.auto3",
    "fio_type-libpmem_nt-true_sync-true.auto3",
    "fio_type-libpmem_nt-true_sync-false.auto3"
]
pltypes = ["fsdax_mmap","fsdax_syswrite", "libpmem", "pmemblk", "dev-dax"]
pltypes = ["fsdax_mmap","fsdax_syswrite", "libpmem_nt_drain", "libpmem_nt_nodrain", "libpmem_t_drain", "libpmem_t_nodrain", "pmemblk", "dev-dax"]

plottypes = {
    'fsdax_mmap': ("fio_type-fsdax.auto3", "fsdax_mmap"),
    'fsdax_syswrite': ("fio_type-fsdax.auto3", "fsdax_syswrite"),
    'dev-dax': ("fio_type-dev-dax.auto3", "dev-dax"),
    'pmemblk': ("fio_type-pmemblk.auto3", "pmemblk"),
    'libpmem_nt_drain': ("fio_type-libpmem_nt-true_sync-true.auto3", "libpmem"),
    'libpmem_nt_nodrain': ("fio_type-libpmem_nt-true_sync-false.auto3", "libpmem"),
    'libpmem_t_drain': ("fio_type-libpmem_nt-false_sync-true.auto3", "libpmem"),
    'libpmem_t_nodrain': ("fio_type-libpmem_nt-false_sync-false.auto3", "libpmem"),
}

for recipename in recipenames:
    for cpu in cpus:
        for bsize in bsizes:
            for plottype in plottypes:
                key = getkey(cpu, bsize, plottypes[plottype])
                datafile = getdatafile(projname, recipename, cpu, bsize, plottypes[plottype])
                datadict[key] = {}
                if not os.path.exists(datafile):
                    continue
                tmp = json.load(open(datafile, 'r'))
                datadict[key]["global options"] = tmp["global options"]
                datadict[key]["jobs"] = {}
                for j in tmp["jobs"]:
                    datadict[key]["jobs"][j["jobname"]] = j

# print(datadict.keys())
# print(datadict["1-fsdax_mmap"]["global options"])
# print(datadict["1-fsdax_mmap"]["jobs"].keys())
# sys.exit()

def plotA(pltype, bsize):
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

    for cpu in cpus:
        label = getkey(cpu, bsize, plottypes[plottype])
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
    bar.set_title("%s bs=%s" % (plottype, bsize))
    fig = bar.get_figure()
    fig.savefig("/tmp/fio/figure-%s.png" % pltype)

def plotB(pltype, bsize):
    plotdata = []
    plotdataerr = []
    randreads = []
    randwrites = []
    randreadserr = []
    randwriteserr = []

    for cpu in cpus:
        label = getkey(cpu, bsize, plottypes[plottype])
        if not datadict[label]:
            continue
        # print("@@ %s\n" % datadict[label])
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
    bar.set_title("%s bs=%s" % (plottype, bsize))
    fig = bar.get_figure()
    fig.savefig("/tmp/fio/figure-%s.png" % pltype)

ymax = 35
bsize = "4k"
for plottype in plottypes:
    if plottype == "pmemblk":
        plotB(plottype, bsize)
    else:
        plotA(plottype, bsize)
