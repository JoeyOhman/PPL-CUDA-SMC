#include <iostream>
#include <cstring>
#include "../../../Inference/Smc/smc.cuh"
#include "../../../Inference/Smc/smcImpl.cuh"
#include "../../../Utils/distributions.cuh"
#include "../TreeUtils/treeUtils.cuh"
#include "cbd.cuh"

// nvcc -arch=sm_75 -rdc=true Src/Models/Phylogenetics/CBD/cbdDoublyLinked.cu Src/Utils/*.cpp -o smc.exe -lcudadevrt -std=c++11 -O3 -D GPU

// g++ -x c++ Src/Models/Phylogenetics/CBD/cbdDoublyLinked.cu Src/Utils/*.cpp -o smc.exe -std=c++11 -O3

BBLOCK_DATA(tree, tree_t, 1)
BBLOCK_DATA(lambda, floating_t, 1) // prolly faster to just pass these as args... they should be generated in particle anyway?
BBLOCK_DATA(mu, floating_t, 1)

floating_t corrFactor;

void initCBD() {

    // lambda ~ gamma( 1.0, 1.0 )
    // mu     ~ gamma( 1.0, 1.0 )

    *lambda = 0.2; // birth rate
    *mu = 0.1; // death rate

    int numLeaves = countLeaves(tree->idxLeft, tree->idxRight, NUM_NODES);
    // floating_t corrFactor = (numLeaves - 1) * log(2.0) - lnFactorial(numLeaves);
    // setLogCorrectionFactor(corrFactor);
    corrFactor = (numLeaves - 1) * log(2.0) - lnFactorial(numLeaves);

    COPY_DATA_GPU(tree, tree_t, 1)
    COPY_DATA_GPU(lambda, floating_t, 1)
    COPY_DATA_GPU(mu, floating_t, 1)

}

BBLOCK_HELPER(survival, {

    floating_t lambdaLocal = *DATA_POINTER(lambda);
    floating_t muLocal = *DATA_POINTER(mu);

    floating_t t = BBLOCK_CALL(sampleExponential, lambdaLocal + muLocal);

    floating_t currentTime = startTime - t;
    if(currentTime < 0)
        return true;
    else {
        bool speciation = BBLOCK_CALL(flipK, lambdaLocal / (lambdaLocal + muLocal));
        if (speciation)
            return BBLOCK_CALL(survival, currentTime) || BBLOCK_CALL(survival, currentTime);
        else
            return false;
    }

}, bool, floating_t startTime)


BBLOCK_HELPER(simBranch, {

    floating_t lambdaLocal = *DATA_POINTER(lambda);
    // floating_t muLocal = *DATA_POINTER(mu);

    floating_t t = BBLOCK_CALL(sampleExponential, lambdaLocal);

    floating_t currentTime = startTime - t;

    if(currentTime <= stopTime)
        return;
    
    // WEIGHT(log(2.0));
    
    if(BBLOCK_CALL(survival, currentTime)) {
        WEIGHT(-INFINITY);
        return;
    }

    WEIGHT(log(2.0)); // was previously done above survival call, no reason to do it before though (unless resample occurrs there)
    
    BBLOCK_CALL(simBranch, currentTime, stopTime);

}, void, floating_t startTime, floating_t stopTime)


BBLOCK(condBD2, progState_t, {

    int treeIdx = PSTATE.stack.pop();
    // int treeIdx = loc.treeIdx;

    tree_t* treeP = DATA_POINTER(tree);

    int indexParent = treeP->idxParent[treeIdx];

    BBLOCK_CALL(simBranch, treeP->ages[indexParent], treeP->ages[treeIdx]);

    // match tree with...
    if(treeP->idxLeft[treeIdx] != -1) { // If left branch exists, so does right..
        // WEIGHT(log(2.0 * (*DATA_POINTER(lambda))));
        WEIGHT(log(*DATA_POINTER(lambda)));

        PSTATE.stack.push(treeP->idxRight[treeIdx]);

        PSTATE.stack.push(treeP->idxLeft[treeIdx]);
    }

    PC--;
    // RESAMPLE = true;

})


BBLOCK(condBD1, progState_t, {


    if(PSTATE.stack.stackPointer == 0) {
        PC = 3;
        return;
    }

    int treeIdx = PSTATE.stack.peek();

    // MÅSTE JAG VIKTA EFTER FÖRSTA BRANCHEN AV ROTEN ÄR KLAR?
    if(treeIdx == 2)
        WEIGHT(log(*(DATA_POINTER(lambda)))); 
    

    tree_t* treeP = DATA_POINTER(tree);

    int indexParent = treeP->idxParent[treeIdx];

    WEIGHT(- (*DATA_POINTER(mu)) * (treeP->ages[indexParent] - treeP->ages[treeIdx]));


    PC++;
    // RESAMPLE = true;

})


BBLOCK(cbd, progState_t, {

    tree_t* treeP = DATA_POINTER(tree);


    if(treeP->idxRight[ROOT_IDX] != -1) {
        PSTATE.stack.push(treeP->idxRight[ROOT_IDX]);
    }
    
    PSTATE.stack.push(treeP->idxLeft[ROOT_IDX]);


    //PSTATE.treeIdx = tree->idxLeft[ROOT_IDX];
    //PSTATE.parentIdx = ROOT_IDX;

    // WEIGHT(log(2.0)); 
    // WEIGHT(log(*(DATA_POINTER(lambda)))); 
    // Now assuming that root has 2 children, and weighting before first condBD instead of after. Check if correct?

    /*BBLOCK_CALL(condBD1);
    if(tree->idxRight[ROOT_IDX] != -1) {
        WEIGHT(log(2.0));
        BBLOCK_CALL(condBD, tree->idxRight[ROOT_IDX], ROOT_IDX);
        
    }*/
    PC++;
    // RESAMPLE = false;
    BBLOCK_CALL(condBD1);
})


STATUSFUNC({
    
})


int main() {

    initGen();
    initCBD();
    

    SMCSTART(progState_t)

    INITBBLOCK(cbd, progState_t)
    INITBBLOCK(condBD1, progState_t)
    INITBBLOCK(condBD2, progState_t)

    SMCEND(progState_t)

    res += corrFactor;

    cout << "log(MarginalLikelihood) = " << res << endl;

    return 0;
}
