#include "trace.h"

// Featurelinien beim Glaetten der Patchraender festhalten. Die Glaettung
// in PatchTracer::SmoothPatches erkennt Patchraender an IsFaceEdgeS, und
// das markiert die von aussen vorgegebenen Featurekanten mit -- ohne
// diesen Schalter wandern also auch sie. Aus Vorgabe aus, damit sich am
// bisherigen Verhalten nichts aendert.
bool TraceFixFeatureBorders=false;

// Wie stark die Patchraender geglaettet werden. Die Glaettung haelt die
// Featurelinien punktgenau fest (gemessen: 1460 von 1460 Feature-Vertices
// unverschoben) und bewegt nur die UEBRIGEN Patchraender -- an einem Lauf
// 4409 von 6321 Vertices, bis zu 0.79 Kantenlaengen weit. Sie ist also
// genau der Hebel fuer ungeschickt liegende Patchgrenzen, war aber mit 10
// bzw. 3 Schritten fest verdrahtet.
int TracePatchSmoothSteps=10;
int TracePatchSmoothFinal=3;

// PATCH-TOPOLOGIE. Alles Folgende entscheidet, WELCHE Pfade zu
// Patchgrenzen werden -- also die Aufteilung selbst, nicht ihre Lage.
// Nach dem Tracing steht sie in .patch/.corners und ist fuer den Rest
// der Pipeline unveraenderlich; quad_from_patches quantisiert nur noch
// innerhalb davon. Ein ungeschickt gelegter Patch bleibt ungeschickt.
//
// MinVal/MaxVal begrenzen die Zahl der Patchecken. Mit der Vorgabe 3
// entstehen an der Sickenplatte 28 von 78 Patches mit nur DREI Ecken;
// jeder davon erzwingt eine Singularitaet.
// ENTFERNEN VON PFADEN. Der Tracer legt erst viele Pfade und nimmt dann
// die wieder weg, die er fuer entbehrlich haelt -- an der Sickenplatte 52
// von 80 und noch einmal 22 von 108. Entschieden wird das in
// PatchManager::BetterConfiguration, und dort werden nur Scheibentopologie,
// Eckenzahl (3..5), Emitter und Singularitaeten geprueft. GROESSE UND FORM
// eines Patches kommen in keinem Kriterium vor; sind alle gleich, greift
// das abschliessende "return true", also: im Zweifel entfernen. Deshalb
// gewinnt ein 8 Q langer, 1 Q breiter Streifen gegen zwei quadratische
// Patches -- er hat ebenfalls vier Ecken und erzeugt keine zusaetzliche
// Singularitaet, und weniger Patches gilt als besser.
//
// Beide Schalter aus Vorgabe an, also bisheriges Verhalten.
bool TraceFinalRemoval=true;
bool TracePreRemove=true;

int TraceMinVal=3;
int TraceMaxVal=5;
double TraceCClarkability=1.0;
double TraceDrift=100.0;
double TraceSampleRatio=0.01;

#include <tracing/tracer_interface.h>

bool trace(const std::string& filename_prefix, TraceMesh& traceTrimesh)
{
    std::string meshFilename = filename_prefix + ".obj";
    std::string fieldFilename = filename_prefix + ".rosy";
    std::string sharpFilename = filename_prefix + ".sharp";

    std::cout<<"Loading Remeshed M:"<<meshFilename.c_str()<<std::endl;
    std::cout<<"Loading Rosy Field:"<<fieldFilename.c_str()<<std::endl;
    std::cout<<"Loading Sharp F:"<<sharpFilename.c_str()<<std::endl;

    //Mesh load
    printf("Loading the mesh \n");
    bool loadedMesh=traceTrimesh.LoadMesh(meshFilename);
    if (!loadedMesh) {
        std::cerr << "failed to load mesh from " << meshFilename << std::endl;
        return false;
    }
    traceTrimesh.UpdateAttributes();

    //Field load
    bool loadedField=traceTrimesh.LoadField(fieldFilename);
    if (!loadedField) {
        std::cerr << "failed to load field from " << fieldFilename << std::endl;
        return false;
    }
    traceTrimesh.UpdateAttributes();

    //Sharp load
    bool loadedFeatures=traceTrimesh.LoadSharpFeatures(sharpFilename);
    if (!loadedFeatures) {
        std::cerr << "failed to load features from " << sharpFilename << std::endl;
        return false;
    }
    traceTrimesh.SolveGeometricIssues();
    traceTrimesh.UpdateSharpFeaturesFromSelection();

    //preprocessing mesh
    PreProcessMesh(traceTrimesh);

    //initializing graph
    VertexFieldGraph<TraceMesh> VGraph(traceTrimesh);
    VGraph.InitGraph(false);

    //INIT TRACER
    typedef PatchTracer<TraceMesh> TracerType;
    TracerType PTr(VGraph);
    TraceMesh::ScalarType Drift=TraceDrift;
    bool add_only_needed=true;
    bool final_removal=TraceFinalRemoval;
    bool meta_mesh_collapse=true;
    bool force_split=false;
    PTr.sample_ratio=TraceSampleRatio;
    PTr.CClarkability=TraceCClarkability;
    PTr.split_on_removal=true;
    PTr.away_from_singular=true;
    PTr.match_valence=true;
    PTr.check_quality_functor=false;
    PTr.MinVal=TraceMinVal;
    PTr.MaxVal=TraceMaxVal;
    std::cout<<"Tracing: MinVal "<<TraceMinVal<<", MaxVal "<<TraceMaxVal
             <<", CClarkability "<<TraceCClarkability<<", Drift "<<TraceDrift
             <<", sample_ratio "<<TraceSampleRatio<<std::endl;
    PTr.Concave_Need=1;

    //TRACING
    PTr.InitTracer(Drift,false);
    std::cout<<"Tracing: Pfad-Entfernung final "<<(final_removal?"an":"aus")
             <<", vorab "<<(TracePreRemove?"an":"aus")<<std::endl;
    RecursiveProcess<TracerType>(PTr,Drift, add_only_needed,final_removal,TracePreRemove,meta_mesh_collapse,force_split,true,false,true,TraceFixFeatureBorders,TracePatchSmoothSteps);
    PTr.SmoothPatches(TracePatchSmoothFinal,0.5,true,TraceFixFeatureBorders);
    SaveAllData(PTr,filename_prefix,0,false,false);
    return true;
}
