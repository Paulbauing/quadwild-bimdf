#include "functions.h"
#include "trace.h"

inline void remeshAndField(
        FieldTriMesh& trimesh,
        const Parameters& parameters,
        const std::string& meshFilename,
        const std::string& sharpFilename,
        const std::string& fieldFilename)
{
    typename MeshPrepocess<FieldTriMesh>::BatchParam BPar;
    BPar.DoRemesh=parameters.remesh;
    BPar.feature_erode_dilate=4;
    BPar.remesher_aspect_ratio=0.35; // from field_computation/basic_setup*.txt
    BPar.remesher_iterations=15;
    BPar.remesher_termination_delta=10000;
    BPar.SharpFactor=6;
    BPar.sharp_feature_thr=parameters.sharpAngle;
    BPar.surf_dist_check=true;
    BPar.UpdateSharp=(!parameters.hasFeature);
    BPar.crease_angle=parameters.crease_angle;
    BPar.keep_border=parameters.keepBorder;
    extern bool TraceFixFeatureBorders;
    TraceFixFeatureBorders=parameters.fixFeatureBorders;
    extern int TracePatchSmoothSteps;
    if (parameters.patchSmooth>=0) TracePatchSmoothSteps=parameters.patchSmooth;
    extern int TraceMinVal; extern int TraceMaxVal;
    extern double TraceCClarkability, TraceDrift, TraceSampleRatio;
    if (parameters.traceMinVal>0)  TraceMinVal=parameters.traceMinVal;
    if (parameters.traceMaxVal>0)  TraceMaxVal=parameters.traceMaxVal;
    if (parameters.traceCClark>=0) TraceCClarkability=parameters.traceCClark;
    if (parameters.traceDrift>0)   TraceDrift=parameters.traceDrift;
    if (parameters.traceSampleRatio>0) TraceSampleRatio=parameters.traceSampleRatio;
    extern bool TraceFinalRemoval, TracePreRemove;
    if (parameters.traceFinalRemoval>=0) TraceFinalRemoval=(parameters.traceFinalRemoval!=0);
    if (parameters.tracePreRemove>=0)    TracePreRemove=(parameters.tracePreRemove!=0);

    typename vcg::tri::FieldSmoother<FieldTriMesh>::SmoothParam FieldParam;
    FieldParam.alpha_curv=parameters.alpha_curv;
    FieldParam.curv_thr=0.8;
    std::cout<<"Alpha Curvature: "<<FieldParam.alpha_curv<<std::endl;

    if (parameters.hasFeature) {
        bool loaded=trimesh.LoadSharpFeatures(sharpFilename);
        if (!loaded)
        {
            std::cout<<"ERROR: Wrong Sharp Feature File"<<std::endl;
            exit(0);
        }
        std::cout<<"Sharp Feature Length:"<<trimesh.SharpLenght()<<std::endl;
    }
    if (!parameters.hasField) {
        MeshPrepocess<FieldTriMesh>::BatchProcess(trimesh,BPar,FieldParam);
    }
    else {
        bool success = trimesh.LoadField(fieldFilename.c_str());
        if (!success) {
            throw std::runtime_error(std::string("failed to load field  from '") + fieldFilename + "'");
        }
    }

    MeshPrepocess<FieldTriMesh>::SaveAllData(trimesh,meshFilename);
}


inline void quadrangulate(
        const std::string& filename,
        TriangleMesh& trimeshToQuadrangulate,
        PolyMesh& quadmesh,
        std::vector<std::vector<size_t>>& trimeshPartitions,
        std::vector<std::vector<size_t>>& trimeshCorners,
        std::vector<std::pair<size_t,size_t>>& trimeshFeatures,
        std::vector<size_t>& trimeshFeaturesC,
        std::vector<std::vector<size_t>> quadmeshPartitions,
        std::vector<std::vector<size_t>> quadmeshCorners,
        std::vector<int> ilpResult,
        const Parameters& parameters)
{
    //Get base filename
    std::string baseFilename=filename;
    baseFilename.erase(baseFilename.find_last_of("."));

    std::string meshFilename=baseFilename;
    meshFilename.append("_p0.obj");

    int mask;
    vcg::tri::io::ImporterOBJ<TriangleMesh>::LoadMask(meshFilename.c_str(), mask);
    int err = vcg::tri::io::ImporterOBJ<TriangleMesh>::Open(trimeshToQuadrangulate, meshFilename.c_str(), mask);
    if ((err!=0)&&(err!=5)) {
        throw std::runtime_error("error importing obj file " + meshFilename);
    }

    //FACE PARTITIONS
    std::string partitionFilename = baseFilename;
    partitionFilename.append("_p0.patch");
    trimeshPartitions = loadPatches(partitionFilename);
    std::cout<<"Loaded "<<trimeshPartitions.size()<<" patches"<<std::endl;

    //PATCH CORNERS
    std::string cornerFilename = baseFilename;
    cornerFilename.append("_p0.corners");
    trimeshCorners = loadCorners(cornerFilename);
    std::cout<<"Loaded "<<trimeshCorners.size()<<" corners set"<<std::endl;

    //FEATURES
    std::string featureFilename = baseFilename;
    featureFilename.append("_p0.feature");
    trimeshFeatures = LoadFeatures(featureFilename);
    std::cout<<"Loaded "<<trimeshFeatures.size()<<" features"<<std::endl;

    //FEATURE CORNERS
    std::string featureCFilename = baseFilename;
    featureCFilename.append("_p0.c_feature");
    trimeshFeaturesC = loadFeatureCorners(featureCFilename);
    std::cout<<"Loaded "<<trimeshFeaturesC.size()<<" corner features"<<std::endl;
    loadFeatureCorners(featureCFilename);

    std::cout<<"Alpha: "<<parameters.alpha<<std::endl;

    OrientIfNeeded(trimeshToQuadrangulate,trimeshPartitions,trimeshCorners,trimeshFeatures,trimeshFeaturesC);

    //COMPUTE QUADRANGULATION
    QuadRetopology::internal::updateAllMeshAttributes(trimeshToQuadrangulate);

    QuadRetopology::Parameters qParameters;
    float scaleFactor;
    int fixedChartClusters;

    qParameters.alpha=parameters.alpha;
    qParameters.ilpMethod=QuadRetopology::ILPMethod::LEASTSQUARES;
    qParameters.timeLimit=200;
    qParameters.gapLimit=0.0;
    qParameters.callbackTimeLimit.push_back(3.0);
    qParameters.callbackTimeLimit.push_back(5.0);
    qParameters.callbackTimeLimit.push_back(10.0);
    qParameters.callbackTimeLimit.push_back(20.0);
    qParameters.callbackTimeLimit.push_back(30.0);
    qParameters.callbackTimeLimit.push_back(60.0);
    qParameters.callbackTimeLimit.push_back(90.0);
    qParameters.callbackTimeLimit.push_back(120.0);

    qParameters.callbackGapLimit.push_back(0.005);
    qParameters.callbackGapLimit.push_back(0.02);
    qParameters.callbackGapLimit.push_back(0.05);
    qParameters.callbackGapLimit.push_back(0.1);
    qParameters.callbackGapLimit.push_back(0.15);
    qParameters.callbackGapLimit.push_back(0.20);
    qParameters.callbackGapLimit.push_back(0.25);
    qParameters.callbackGapLimit.push_back(0.3);

    qParameters.minimumGap=0.4;

    qParameters.isometry=true;

    qParameters.regularityQuadrilaterals=true;

    qParameters.regularityNonQuadrilaterals=true;

    qParameters.regularityNonQuadrilateralsWeight=0.9;

    qParameters.alignSingularities=true;

    qParameters.alignSingularitiesWeight=0.1;

    qParameters.repeatLosingConstraintsIterations=true;

    qParameters.repeatLosingConstraintsQuads=false;

    qParameters.repeatLosingConstraintsNonQuads=false;

    qParameters.repeatLosingConstraintsAlign=true;

    qParameters.hardParityConstraint=true;

    scaleFactor=parameters.scaleFact;

    fixedChartClusters=300; //  TODO: load from parameter struct / file
    fixedChartClusters=0;

    qParameters.chartSmoothingIterations = 0; //Chart smoothing
    qParameters.quadrangulationFixedSmoothingIterations = 0; //Smoothing with fixed borders of the patches
    qParameters.quadrangulationNonFixedSmoothingIterations = 0; //Smoothing with fixed borders of the quadrangulation
    qParameters.feasibilityFix = false;

    double edgeSize=avgEdge(trimeshToQuadrangulate)*scaleFactor;
    std::cout<<"Edge size: "<<edgeSize<<std::endl;
    const std::vector<double> edgeFactor(trimeshPartitions.size(), edgeSize);

    qfp::quadrangulationFromPatches(trimeshToQuadrangulate, trimeshPartitions, trimeshCorners, edgeFactor, qParameters, fixedChartClusters, quadmesh, quadmeshPartitions, quadmeshCorners, ilpResult);

    //SAVE OUTPUT
    std::string outputFilename = baseFilename;
    outputFilename+=std::string("_quadrangulation")+std::string(".obj");
    vcg::tri::io::ExporterOBJ<PolyMesh>::Save(quadmesh, outputFilename.c_str(),0);


    //SMOOTH
    std::vector<size_t> QuadPart(quadmesh.face.size(),0);
    for (size_t i=0;i<quadmeshPartitions.size();i++)
        for (size_t j=0;j<quadmeshPartitions[i].size();j++)
            QuadPart[quadmeshPartitions[i][j]]=i;

    std::vector<size_t> TriPart(trimeshToQuadrangulate.face.size(),0);
    for (size_t i=0;i<trimeshPartitions.size();i++)
        for (size_t j=0;j<trimeshPartitions[i].size();j++)
            TriPart[trimeshPartitions[i][j]]=i;

    std::vector<size_t> QuadCornersVect;
    for (size_t i=0;i<quadmeshCorners.size();i++)
        for (size_t j=0;j<quadmeshCorners[i].size();j++)
            QuadCornersVect.push_back(quadmeshCorners[i][j]);

    std::sort(QuadCornersVect.begin(),QuadCornersVect.end());
    auto last=std::unique(QuadCornersVect.begin(),QuadCornersVect.end());
    QuadCornersVect.erase(last, QuadCornersVect.end());

    std::cout<<"** SMOOTHING **"<<std::endl;
    MultiCostraintSmooth(quadmesh,trimeshToQuadrangulate,trimeshFeatures,trimeshFeaturesC,TriPart,QuadCornersVect,QuadPart,0.5,edgeSize,30,1);

    //SAVE OUTPUT
    std::string smoothOutputFilename = baseFilename;
    smoothOutputFilename+=std::string("_quadrangulation_smooth")+std::string(".obj");

    vcg::tri::io::ExporterOBJ<PolyMesh>::Save(quadmesh, smoothOutputFilename.c_str(),0);
}

inline typename TriangleMesh::ScalarType avgEdge(const TriangleMesh& trimesh)
{
    typedef typename TriangleMesh::ScalarType ScalarType;

    ScalarType avg=0;
    size_t num=0;

    for (size_t i=0;i<trimesh.face.size();i++) {
        for (int j=0;j<trimesh.face[i].VN();j++) {
            avg+=(trimesh.face[i].cP0(j)-trimesh.face[i].cP1(j)).Norm();
            num++;
        }
    }

    return avg/num;
}

inline bool loadConfigFile(const std::string& filename, Parameters& parameters)
{
    FILE *f=fopen(filename.c_str(),"rt");

    if (f==NULL) {
        throw std::runtime_error(std::string("Failed to open config file ") + filename);
    }

    std::cout<<"READ CONFIG FILE"<<std::endl;

    int IntVar;
    fscanf(f,"do_remesh %d\n",&IntVar);
    if (IntVar==0)
        parameters.remesh=false;
    else
        parameters.remesh=true;

    // Optional -- aeltere Config-Dateien haben die Zeile nicht, dann
    // bleibt es beim bisherigen Verhalten (Rand wird nicht geschont).
    {
        int TmpVar = 0;
        if (fscanf(f,"keep_border %d\n",&TmpVar) == 1)
            parameters.keepBorder = (TmpVar != 0);
    }
    {
        int TmpVar = 0;
        if (fscanf(f,"fix_feature_borders %d\n",&TmpVar) == 1)
            parameters.fixFeatureBorders = (TmpVar != 0);
    }
    {
        int TmpVar = -1;
        if (fscanf(f,"patch_smooth %d\n",&TmpVar) == 1)
            parameters.patchSmooth = TmpVar;
    }
    {
        int A=-1,B=-1; float C=-1,D=-1,E=-1;
        if (fscanf(f,"trace_minval %d\n",&A) == 1) parameters.traceMinVal=A;
        if (fscanf(f,"trace_maxval %d\n",&B) == 1) parameters.traceMaxVal=B;
        if (fscanf(f,"trace_cclark %f\n",&C) == 1) parameters.traceCClark=C;
        if (fscanf(f,"trace_drift %f\n",&D) == 1) parameters.traceDrift=D;
        if (fscanf(f,"trace_sampleratio %f\n",&E) == 1) parameters.traceSampleRatio=E;
    }
    {
        int A2=-1,B2=-1;
        if (fscanf(f,"trace_final_removal %d\n",&A2) == 1) parameters.traceFinalRemoval=A2;
        if (fscanf(f,"trace_pre_remove %d\n",&B2) == 1) parameters.tracePreRemove=B2;
    }

    fscanf(f,"sharp_feature_thr %f\n",&parameters.sharpAngle);

    fscanf(f,"alpha %f\n",&parameters.alpha);

    fscanf(f,"scaleFact %f\n",&parameters.scaleFact);

    // Optional -- aeltere Config-Dateien haben diese Zeile nicht. fscanf
    // liefert dann 0 Treffer und laesst parameters.alpha_curv unberuehrt,
    // also beim Default aus dem Parameters()-Konstruktor (0.3, der bisher
    // hart verdrahtete Wert). Kein Fehlerfall, kein Abbruch noetig.
    fscanf(f,"alpha_curv %f\n",&parameters.alpha_curv);

    // Ebenfalls optional; fehlt die Zeile, bleibt der Default 25.
    fscanf(f,"crease_angle %f\n",&parameters.crease_angle);

    fclose(f);

    std::cout << "Successful config import" << std::endl;

    return true;
}
