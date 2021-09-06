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

def getdatafile(plottype, cpu, bsize):
    return "./work/%s/pmem/%s/1-1/c%d_bs%s/%s.json" % (plottype[0], plottype[1], cpu, bsize, plottype[2])

def getkey(plottype, cpu, bsize):
    return "%s_c%d_bs%s_%s" % (plottype[1], cpu, bsize, plottype[2])

cpus = [1, 2, 4, 8, 16, 32, 64]
pltypes = ["fsdax_mmap","fsdax_syswrite", "libpmem", "pmemblk", "dev-dax"]

projname = "210714_fio8"
cpus = [1, 2, 4, 8, 16, 32]
bsizes = ["4k", "2m"]
pltypes = ["fsdax_mmap","fsdax_syswrite", "libpmem_nt_drain", "libpmem_nt_nodrain", "libpmem_t_drain", "libpmem_t_nodrain", "pmemblk", "dev-dax"]

plottypes = {
    'fsdax_mmap':             ("210714_fio8", "fio_type-fsdax.auto3", "fsdax_mmap", "XFS"),
    'fsdax_syswrite':         ("210714_fio8", "fio_type-fsdax.auto3", "fsdax_syswrite", "XFS"),
    'dev-dax':                ("210714_fio8", "fio_type-dev-dax.auto3", "dev-dax", ""),
    'pmemblk':                ("210714_fio8", "fio_type-pmemblk.auto3", "pmemblk", "XFS"),
    'libpmem_ntstore_sfence': ("210714_fio8", "fio_type-libpmem_nt-true_sync-true.auto3", "libpmem", "XFS"),
    'libpmem_ntstore':        ("210714_fio8", "fio_type-libpmem_nt-true_sync-false.auto3", "libpmem", "XFS"),
    'libpmem_clwb_sfence':    ("210714_fio8", "fio_type-libpmem_nt-false_sync-true.auto3", "libpmem", "XFS"),
    'libpmem_clwb':           ("210714_fio8", "fio_type-libpmem_nt-false_sync-false.auto3", "libpmem", "XFS"),
    'pmemblk_striped_pmem':   ("210716_fio2", "fio_dm_type-pmemblk.auto3", "pmemblk", "XFS"),
    'libpmem_striped_pmem':   ("210716_fio2", "fio_dm_type-libpmem_nt-true_sync-true.auto3", "libpmem", "XFS"),
    'fsdax_mmap_striped_pmem':     ("210716_fio2", "fio_dm_type-fsdax.auto3", "fsdax_mmap", "XFS"),
    'fsdax_syswrite_striped_pmem': ("210716_fio2", "fio_dm_type-fsdax.auto3", "fsdax_syswrite", "XFS"),
    'pmemblk_ext4':           ("210716_fio3", "fio_ext4_type-pmemblk.auto3", "pmemblk", "ext4"),
    'libpmem_ext4':           ("210716_fio3", "fio_ext4_type-libpmem_nt-true_sync-true.auto3", "libpmem", "ext4"),
    'fsdax_mmap_ext4':        ("210716_fio3", "fio_ext4_type-fsdax.auto3", "fsdax_mmap", "ext4"),
    'fsdax_syswrite_ext4':    ("210716_fio3", "fio_ext4_type-fsdax.auto3", "fsdax_syswrite", "ext4"),
}

for cpu in cpus:
    for bsize in bsizes:
        for plottype in plottypes:
            key = getkey(plottypes[plottype], cpu, bsize)
            datafile = getdatafile(plottypes[plottype], cpu, bsize)
            datadict[key] = {}
            if not os.path.exists(datafile):
                continue
            # print("-- %s" % datafile)
            tmp = json.load(open(datafile, 'r'))
            datadict[key]["global options"] = tmp["global options"]
            datadict[key]["jobs"] = {}
            for j in tmp["jobs"]:
                datadict[key]["jobs"][j["jobname"]] = j

# print(datadict.keys())
# print(datadict["1-fsdax_mmap"]["global options"])
# print(datadict["1-fsdax_mmap"]["jobs"].keys())
# sys.exit()

def plotA(pltype, bsize, outdir):
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

    print("-- %s" % pltype)
    for cpu in cpus:
        label = getkey(plottypes[plottype], cpu, bsize)
        print(label)
        if not datadict[label]:
            continue
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

    if len(randreads) != len(cpus):
        return
    if len(randwrites) != len(cpus):
        return
    if len(seqreads) != len(cpus):
        return
    if len(seqwrites) != len(cpus):
        return
    
    plotdata2 = pd.DataFrame({"RandRead": randreads, "RandWrite": randwrites, "SeqRead": seqreads, "SeqWrite":seqwrites}, index=cpus)
    bar = plotdata2.plot.bar(rot=0, yerr={"RandRead": randreadserr, "RandWrite": randwriteserr, "SeqRead": seqreadserr, "SeqWrite":seqwriteserr})
    bar.set_xlabel('NumJobs')
    bar.set_ylabel('Throughput (GiB/s)')
    bar.set_ylim(0, ymax)
    bar.set_title("%s bs=%s" % (plottype, bsize))
    fig = bar.get_figure()
    fig.savefig("%s/figure-%s.png" % (outdir, pltype))

def plotB(pltype, bsize, outdir):
    plotdata = []
    plotdataerr = []
    randreads = []
    randwrites = []
    randreadserr = []
    randwriteserr = []

    for cpu in cpus:
        label = getkey(plottypes[plottype], cpu, bsize)
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
    fig.savefig("%s/figure-%s.png" % (outdir, pltype))

ymax = 35
for bs in bsizes:
    bsize = bs
    outdir = "./%s/%s" % (projname, bsize)
    if not os.path.exists(outdir):
        os.makedirs(outdir)
    for plottype in plottypes:
        plotA(plottype, bsize, outdir)
