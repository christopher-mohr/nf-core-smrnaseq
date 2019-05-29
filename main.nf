#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/smrnaseq
========================================================================================
 nf-core/smrnaseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/smrnaseq
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/smrnaseq --reads '*.fastq.gz' --genome GRCh37 -profile docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes).
                                    NOTE! Paired-end data is NOT supported by this pipeline! For paired-end data, use Read 1 only
      --genome                      Name of iGenomes reference

    References
      --saveReference               Save the generated reference files the the Results directory
      --mature                      Path to the FASTA file of mature miRNAs
      --hairpin                     Path to the FASTA file of miRNA precursors
      --bt_index                    Path to the bowtie 1 index files of the host reference genome
      --mirtrace_species            Species for miRTrace. Pre-defined when '--genome' is specified

    Trimming options
      --min_length [int]                Discard reads that became shorter than length [int] because of either quality or adapter trimming. Default: 18
      --clip_R1 [int]               Instructs Trim Galore to remove bp from the 5' end of read 1
      --three_prime_clip_R1 [int]   Instructs Trim Galore to remove bp from the 3' end of read 1 AFTER adapter/quality trimming has been performed

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic
      --seq_center                   Text about sequencing center which will be added in the header of output bam files
      --protocol                    Library preparation protocol. Default: "illumina". Can be set as "illumina", "nextflex", "qiaseq" or "cats"
      --three_prime_adapter         3’ Adapter to trim. Default: None
      --skipQC                     Skip all QC steps aside from MultiQC
      --skipFastqc                 Skip FastQC
      --skipMultiqc                Skip MultiQC
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on

    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help message
if (params.help){
    helpMessage()
    exit 0
}


// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// Genome options
params.gtf = params.genome ? params.genomes[ params.genome ].gtf ?: false : false
params.bt_index = params.genome ? params.genomes[ params.genome ].bowtie ?: false : false
params.bt_indices = null
params.mature = params.genome ? params.genomes[ params.genome ].mature ?: false : false
params.hairpin = params.genome ? params.genomes[ params.genome ].hairpin ?: false : false
params.mirtrace_species = params.genome ? params.genomes[ params.genome ].mirtrace_species ?: false : false


// Define regular variables so that they can be overwritten
clip_R1 = params.clip_R1
three_prime_clip_R1 = params.three_prime_clip_R1
three_prime_adapter = params.three_prime_adapter

// Presets
if (params.protocol == "illumina"){
    clip_R1 = 0
    three_prime_clip_R1 = 0
    three_prime_adapter = "TGGAATTCTCGGGTGCCAAGG"
} else if (params.protocol == "nextflex"){
    clip_R1 = 4
    three_prime_clip_R1 = 4
    three_prime_adapter = "TGGAATTCTCGGGTGCCAAGG"
} else if (params.protocol == "qiaseq"){
    clip_R1 = 0
    three_prime_clip_R1 = 0
    three_prime_adapter = "AACTGTAGGCACCATCAAT"
} else if (params.protocol == "cats"){
    clip_R1 = 3
    three_prime_clip_R1 = 0
    three_prime_adapter = "GATCGGAAGAGCACACGTCTG"
} else {
    exit 1, "Invalid library preparation protocol!"
}


// Validate inputs
if( !params.mature || !params.hairpin ){
    exit 1, "Missing mature / hairpin reference indexes! Is --genome specified?"
}

if (params.mature) { mature = file(params.mature, checkIfExists: true) } else { exit 1, "Mature file not found: ${params.mature}" }

if (params.hairpin) { hairpin = file(params.hairpin, checkIfExists: true) } else { exit 1, "Hairpin file not found: ${params.hairpin}" }

if (params.gtf) { gtf = file(params.gtf, checkIfExists: true) }

if( params.bt_index ){
    bt_index = file("${params.bt_index}.fa")
    bt_indices = Channel.fromPath( "${params.bt_index}*.ebwt" ).toList()
    if( !bt_index.exists() ) exit 1, "Reference genome for Bowtie 1 not found: ${params.bt_index}"
} else if( params.bt_indices ){
    bt_indices = Channel.from(params.readPaths).map{ file(it) }.toList()
}
if( !params.gtf || !params.bt_index) {
    log.info "No GTF / Bowtie 1 index supplied - host reference genome analysis will be skipped."
}
if( !params.mirtrace_species ){
    exit 1, "Reference species for miRTrace is not defined."
}
multiqc_config = file(params.multiqc_config)

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config, checkIfExists: true)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

/*
 * Create a channel for input read files
 */
if(params.readPaths){
    Channel
        .from(params.readPaths)
        .map { file(it) }
        .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
        .into { raw_reads_fastqc; raw_reads_trimgalore; raw_reads_mirtrace }
} else {
    Channel
        .fromPath( params.reads )
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}" }
        .into { raw_reads_fastqc; raw_reads_trimgalore; raw_reads_mirtrace }
}

// Header log info
log.info nfcoreHeader()
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
def summary = [:]
summary['Run Name']            = custom_runName ?: workflow.runName
summary['Reads']               = params.reads
summary['Genome']              = params.genome
summary['Min Trimmed Length']     = params.min_length
summary["Trim 5' R1"]          = clip_R1
summary["Trim 3' R1"]          = three_prime_clip_R1
summary['miRBase mature']      = params.mature
summary['miRBase hairpin']     = params.hairpin
if(params.bt_index)            summary['Bowtie Index for Ref'] = params.bt_index
if(params.gtf)                 summary['GTF Annotation'] = params.gtf
summary['Save Reference']      = params.saveReference ? 'Yes' : 'No'
summary['Protocol']            = params.protocol
summary['miRTrace species']    = params.mirtrace_species
summary["3' adapter"]          = three_prime_adapter
summary['Output dir']          = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Current home']        = "$HOME"
summary['Current user']        = "$USER"
summary['Current path']        = "$PWD"
summary['Script dir']          = workflow.projectDir
summary['Config Profile'] = (workflow.profile == 'standard' ? 'UPPMAX' : workflow.profile)
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-smrnaseq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/smrnaseq Workflow Summary'
    section_href: 'https://github.com/nf-core/smrnaseq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
* Parse software version numbers
*/
process get_software_versions {
   publishDir "${params.outdir}/pipeline_info", mode: 'copy',
   saveAs: {filename ->
       if (filename.indexOf(".csv") > 0) filename
       else null
   }

   output:
   file 'software_versions_mqc.yaml' into software_versions_yaml
   file "software_versions.csv"

   script:
   """
   echo $workflow.manifest.version > v_pipeline.txt
   echo $workflow.nextflow.version > v_nextflow.txt
   echo \$(R --version 2>&1) > v_R.txt
   fastqc --version > v_fastqc.txt
   trim_galore --version > v_trim_galore.txt
   bowtie --version > v_bowtie.txt
   samtools --version > v_samtools.txt
   htseq-count -h > v_htseq.txt
   fasta_formatter -h > v_fastx.txt
   mirtrace --version > v_mirtrace.txt
   multiqc --version > v_multiqc.txt
   scrape_software_versions.py > software_versions_mqc.yaml
   """
}

/*
 * PREPROCESSING - Build Bowtie index for mature and hairpin
 */
process makeBowtieIndex {
    label 'process_medium'
    publishDir path: { params.saveReference ? "${params.outdir}/bowtie/reference" : params.outdir },
               saveAs: { params.saveReference ? it : null }, mode: 'copy'

    input:
    file mature from mature
    file hairpin from hairpin

    output:
    file 'mature_idx.*' into mature_index
    file 'hairpin_idx.*' into hairpin_index

    script:
    """
    fasta_formatter -w 0 -i $mature -o mature_igenome.fa
    fasta_nucleotide_changer -d -i mature_igenome.fa -o mature_idx.fa
    bowtie-build mature_idx.fa mature_idx
    fasta_formatter -w 0 -i $hairpin -o hairpin_igenome.fa
    fasta_nucleotide_changer -d -i hairpin_igenome.fa -o hairpin_idx.fa
    bowtie-build hairpin_idx.fa hairpin_idx
    """
}

/*
 * STEP 1 - FastQC
 */
process fastqc {
    label 'process_low'
    tag "$reads"
    publishDir "${params.outdir}/fastqc", mode: 'copy'

    when:
    !params.skip_qc && !params.skip_fastqc

    input:
    file reads from raw_reads_fastqc

    output:
    file '*_fastqc.{zip,html}' into fastqc_results

    script:
    """
    fastqc -q $reads
    """
}


/*
 * STEP 2 - Trim Galore!
 */
process trim_galore {
    label 'process_low'
    tag "$reads"
    publishDir "${params.outdir}/trim_galore", mode: 'copy'

    input:
    file reads from raw_reads_trimgalore

    output:
    file '*.gz' into trimmed_reads_bowtie, trimmed_reads_bowtie_ref, trimmed_reads_insertsize
    file '*trimming_report.txt' into trimgalore_results
    file "*_fastqc.{zip,html}" into trimgalore_fastqc_reports

    script:
    tg_length = "--length ${params.min_length}"
    c_r1 = clip_R1 > 0 ? "--clip_R1 ${clip_R1}" : ''
    tpc_r1 = three_prime_clip_R1 > 0 ? "--three_prime_clip_R1 ${three_prime_clip_R1}" : ''
    tpa = (params.protocol == "qiaseq" | params.protocol == "cats") ? "--adapter ${three_prime_adapter}" : '--small_rna'
    """
    trim_galore $tpa $tg_length $c_r1 $tpc_r1 --gzip $reads --fastqc
    """
}



/*
 * STEP 2.1 - Insertsize
 */

process insertsize {
    label 'process_low'
    tag "$reads"
    publishDir "${params.outdir}/trim_galore/insertsize", mode: 'copy'

    input:
    file reads from trimmed_reads_insertsize

    output:
    file '*.insertsize' into insertsize_results

    script:
    prefix = reads.toString() - ~/(.R1)?(_R1)?(_trimmed)?(\.fq)?(\.fastq)?(\.gz)?$/
    """
    awk 'NR%4 == 2 {lengths[length(\$0)]++} END {for (l in lengths) {print l, lengths[l]}}' <(zcat $reads) >${prefix}.insertsize
    """
}


/*
 * STEP 3 - Bowtie miRBase mature miRNA
 */
process bowtie_miRBase_mature {
    label 'process_medium'
    tag "$reads"
    publishDir "${params.outdir}/bowtie/miRBase_mature", mode: 'copy', pattern: '*.mature_unmapped.fq.gz'

    input:
    file reads from trimmed_reads_bowtie
    file index from mature_index

    output:
    file '*.mature.bam' into miRBase_mature_bam
    file '*.mature_unmapped.fq.gz' into mature_unmapped_reads

    script:
    index_base = index.toString().tokenize(' ')[0].tokenize('.')[0]
    prefix = reads.toString() - ~/(.R1)?(_R1)?(_trimmed)?(\.fq)?(\.fastq)?(\.gz)?$/
    seqCenter = params.seqCenter ? "--sam-RG ID:${prefix} --sam-RG 'CN:${params.seqCenter}'" : ''
    """
    bowtie \\
        $index_base \\
        -q <(zcat $reads) \\
        -p 2 \\
        -t \\
        -k 1 \\
        -m 1 \\
        --best \\
        --strata \\
        -e 99999 \\
        --chunkmbs 2048 \\
        --un ${prefix}.mature_unmapped.fq \\
        -S $seqCenter \\
        | samtools view -bS - > ${prefix}.mature.bam

    gzip ${prefix}.mature_unmapped.fq
    """
}

/*
 * STEP 4 - Bowtie against miRBase hairpin
 */
process bowtie_miRBase_hairpin {
    label 'process_medium'
    tag "$reads"
    publishDir "${params.outdir}/bowtie/miRBase_hairpin", mode: 'copy', pattern: '*.hairpin_unmapped.fq.gz'

    input:
    file reads from mature_unmapped_reads
    file index from hairpin_index

    output:
    file '*.hairpin.bam' into miRBase_hairpin_bam
    file '*.hairpin_unmapped.fq.gz' into hairpin_unmapped_reads

    script:
    index_base = index.toString().tokenize(' ')[0].tokenize('.')[0]
    prefix = reads.toString() - '.mature_unmapped.fq.gz'
    seqCenter = params.seqCenter ? "--sam-RG ID:${prefix} --sam-RG 'CN:${params.seqCenter}'" : ''
    """
    bowtie \\
        $index_base \\
        -p 2 \\
        -t \\
        -k 1 \\
        -m 1 \\
        --best \\
        --strata \\
        -e 99999 \\
        --chunkmbs 2048 \\
        -q <(zcat $reads) \\
        --un ${prefix}.hairpin_unmapped.fq \\
        -S $seqCenter \\
        | samtools view -bS - > ${prefix}.hairpin.bam

    gzip ${prefix}.hairpin_unmapped.fq
    """
}



/*
 * STEP 5.1 - Post-alignment processing for miRBase mature and hairpin
 */
def wrap_mature_and_hairpin = { file ->
    if ( file.contains("mature") ) return "miRBase_mature/$file"
    if ( file.contains("hairpin") ) return "miRBase_hairpin/$file"
}

process miRBasePostAlignment {
    label 'process_medium'
    tag "$input"
    publishDir "${params.outdir}/bowtie", mode: 'copy', saveAs: wrap_mature_and_hairpin

    input:
    file input from miRBase_mature_bam.mix(miRBase_hairpin_bam)

    output:
    file "${input.baseName}.count" into miRBase_counts
    file "${input.baseName}.sorted.bam" into miRBase_bam
    file "${input.baseName}.sorted.bam.bai" into miRBase_bai

    script:
    """
    samtools sort ${input.baseName}.bam -o ${input.baseName}.sorted.bam
    samtools index ${input.baseName}.sorted.bam
    samtools idxstats ${input.baseName}.sorted.bam > ${input.baseName}.count
    """
}


/*
 * STEP 5.2 - edgeR miRBase feature counts processing
 */
process edgeR_miRBase {
    label 'process_low'
    label 'process_ignore'
    publishDir "${params.outdir}/edgeR", mode: 'copy', saveAs: wrap_mature_and_hairpin

    input:
    file input_files from miRBase_counts.toSortedList()

    output:
    file '*.{txt,pdf}' into edgeR_miRBase_results

    script:
    """
    edgeR_miRBase.r $input_files
    """
}


/*
 * STEP 6.1 and 6.2 IF A GENOME SPECIFIED ONLY!
 */
if( params.gtf && params.bt_index) {

    /*
     * STEP 6.1 - Bowtie 1 against reference genome
     */
    process bowtie_ref {
        label 'process_high'
        tag "$reads"
        publishDir "${params.outdir}/bowtie_ref", mode: 'copy'

        input:
        file reads from trimmed_reads_bowtie_ref
        file bt_indices

        output:
        file '*.bowtie.bam' into bowtie_bam, bowtie_bam_for_unmapped

        script:
        index_base = bt_indices[0].toString().tokenize(' ')[0].tokenize('.')[0]
        prefix = reads.toString() - ~/(.R1)?(_R1)?(_trimmed)?(\.fq)?(\.fastq)?(\.gz)?$/
        seqCenter = params.seqCenter ? "--sam-RG ID:${prefix} --sam-RG 'CN:${params.seqCenter}'" : ''
        """
        bowtie \\
            $index_base \\
            -q <(zcat $reads) \\
            -p 8 \\
            -t \\
            -k 10 \\
            -m 1 \\
            --best \\
            --strata \\
            -e 99999 \\
            --chunkmbs 2048 \\
            -S $seqCenter \\
            | samtools view -bS - > ${prefix}.bowtie.bam
        """
    }

    /*
     * STEP 6.2 - Statistics about unmapped reads against ref genome
     */

    process bowtie_unmapped {
        label 'process_ignore'
        label 'process_medium'
        tag "${input_files[0].baseName}"
        publishDir "${params.outdir}/bowtie_ref/unmapped", mode: 'copy'

        input:
        file input_files from bowtie_bam_for_unmapped.toSortedList()

        output:
        file 'unmapped_refgenome.txt' into bowtie_unmapped

        script:
        """
        for i in $input_files
        do
          printf "\${i}\t"
          samtools view -c -f0x4 \${i}
        done > unmapped_refgenome.txt
        """
    }


    /*
     * STEP 6.3 - NGI-Visualizations of Bowtie 1 alignment against host reference genome
     */
    process ngi_visualizations {
        label 'process_low'
        label 'process_ignore'
        tag "$bowtie_bam"
        publishDir "${params.outdir}/bowtie_ref/ngi_visualizations", mode: 'copy'

        input:
        file gtf from gtf
        file bowtie_bam

        output:
        file '*.{png,pdf}' into bowtie_ngi_visualizations

        script:
        // Note! ngi_visualizations needs to be installed!
        // See https://github.com/NationalGenomicsInfrastructure/ngi_visualizations
        """
        #!/usr/bin/env python
        from ngi_visualizations.biotypes import count_biotypes
        count_biotypes.main('$gtf','$bowtie_bam')
        """
    }

}


/*
 * STEP 7 IF A GENOME SPECIFIED ONLY!
 */
if( params.mirtrace_species ) {

    /*
     * STEP 7 - miRTrace
     */
    process mirtrace {
        tag "$reads"
        publishDir "${params.outdir}/miRTrace", mode: 'copy'

         input:
         file reads from raw_reads_mirtrace.collect()

         output:
         file '*mirtrace' into mirtrace_results

         script:
         """
         for i in $reads
         do
             path=\$(realpath \${i})
             prefix=\$(echo \${i} | sed -e "s/.gz//" -e "s/.fastq//" -e "s/.fq//" -e "s/_val_1//" -e "s/_trimmed//" -e "s/_R1//" -e "s/.R1//")
             echo \$path","\$prefix
         done > mirtrace_config

         mirtrace qc \\
             --species $params.mirtrace_species \\
             --adapter $three_prime_adapter \\
             --protocol $params.protocol \\
             --config mirtrace_config \\
             --write-fasta \\
             --output-dir mirtrace \\
             --force
         """
     }

}

/*
 * STEP 8 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    when:
    !params.skip_qc && !params.skip_multiqc

    input:
    file multiqc_config from ch_multiqc_config
    file ('fastqc/*') from fastqc_results.toList()
    file ('trim_galore/*') from trimgalore_results.toList()
    file ('mirtrace/*') from mirtrace_results.toList()
    file ('software_versions/*') from software_versions_yaml.toList()
    file workflow_summary from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc . -f $rtitle $rfilename --config $multiqc_config -m adapterRemoval -m fastqc -m custom_content
    """
}


/*
 * STEP 9 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}




/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/smrnaseq] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/smrnaseq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList){
                log.warn "[nf-core/smrnaseq] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/smrnaseq] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/smrnaseq] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/smrnaseq] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Switch the embedded MIME images with base64 encoded src
    smrnaseqlogo = new File("$baseDir/assets/smrnaseq_logo.png").bytes.encodeBase64().toString()
    scilifelablogo = new File("$baseDir/assets/SciLifeLab_logo.png").bytes.encodeBase64().toString()
    ngilogo = new File("$baseDir/assets/NGI_logo.png").bytes.encodeBase64().toString()
    email_html = email_html.replaceAll(~/cid:smrnaseqlogo/, "data:image/png;base64,$smrnaseqlogo")
    email_html = email_html.replaceAll(~/cid:scilifelablogo/, "data:image/png;base64,$scilifelablogo")
    email_html = email_html.replaceAll(~/cid:ngilogo/, "data:image/png;base64,$ngilogo")

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCountFmt} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCountFmt} ${c_reset}"
    }

    if(workflow.success){
        log.info "${c_purple}[nf-core/smrnaseq]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/smrnaseq]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/rnaseq v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()    
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
