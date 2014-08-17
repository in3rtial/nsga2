module NSGA_II


#Implementation of the NSGA-II multiobjective
#genetic algorithm as described in:

# Revisiting the NSGA-II crowding-distance computation
# Felix-Antoine Fortin
# Marc Parizeau
# Universite Laval, Quebec, PQ, Canada
# GECCO '13 Proceeding of the fifteenth annual conference on Genetic
# and evolutionary computation conference
# Pages 623-630


include("genetic_operators.jl")


#------------------------------------------------------------------------------
#BEGIN type definitions


immutable Individual
  # basic block of the solution
  genes::Vector
  fitness::Vector

  function Individual(genes::Vector, fitness_values::Vector)
    # fitness value is precomputed
    @assert length(genes) != 0
    @assert length(fitness_values) != 0
    new(genes, fitness_values)
  end

  function Individual(genes::Vector, fitness_function::Function)
    # fitness value is to be computed
    @assert length(genes) != 0
    new(genes, fitness_function(genes))
  end
end


type Population
  # the compound of all individuals
  # includes a mapping of fitness values to crowding distance

  individuals::Vector{Individual}
  crowding_distances::Dict{Vector, (Int, FloatingPoint)}

  function Population()
    # initialize empty
    self = new(Individual[], Dict{Vector, (Int, FloatingPoint)}())
  end

  function Population(individuals::Vector{Individual})
    # initialize with individuals but no crowding_distances
    @assert length(individuals) != 0
    d = Dict{Vector, (Int, FloatingPoint)}()
    self = new(individuals, d)
  end

  function Population(individuals::Vector{Individual},
                      crowding_distances::Dict{Vector, (Int, FloatingPoint)})
    # initialize with individuals and crowding_distances
    @assert length(individuals) != 0
    @assert length(distances) != 0
    self = new(individuals, crowding_distances)
  end
end


# hall of fame is a special population to keep
# the best individuals of all generations
typealias HallOfFame Population


#END
#------------------------------------------------------------------------------




#------------------------------------------------------------------------------
#BEGIN NSGA-II helper methods


function non_dominated_compare(a::Vector, b::Vector, comparator = >)
  # non domination comparison operator
  # ([0, 0, 2]  > [0, 0, 1]) =  1
  # ([0, 0, 1] == [0, 1, 0]) =  0
  # ([1, 0, 1]  < [1, 1, 1]) = -1
  @assert length(a) == length(b) "gene vectors must be of same length"
  AdomB = false
  BdomA = false
  for i in zip(a,b)
    if i[1] != i[2]
      if(comparator(i[1], i[2]))
        AdomB = true
      else
        BdomA = true
      end
    end
    if AdomB && BdomA  # immediate return if nondominated
      return 0
    end
  end

  if AdomB
    return 1
  end
  if BdomA
    return -1
  end
  if !AdomB && !BdomA
    return 0
  end
end


function population_init{T}(initializing_function::Function,
                            fitness_function::Function,
                            population_size::Int)
  # used to initialize the first population in the main loop
  # initializing_function must return a vector
  @assert population_size > 0 "population size doesn't make sense"
  population = Population()
  for _ = 1:population_size
    gene_vector = initializing_function()
    push!(population, Individual(gene_vector, fitness_function(gene_vector)))
  end
  population
end


function evaluate_against_others(population::Population,
                                 self_index::Int,
                                 compare_method::Function)
  # compare the fitness of individual individual at index with rest of the population
  domination_count = 0
  dominated_by = Int[]
  self_fitness = population.individuals[index].fitness

  for (i, other) in enumerate(population.individuals)
    if(i != self_index)
      if compare_method(other.fitness, self_fitness) == 1
        domination_count += 1
        push!(dominated_by, i)
      end
    end
  end

  (self_index, domination_count, dominated_by)
end


function fast_delete{T}(array::Vector{T}, to_delete::Vector{T})
  # we take advantage of the knowledge that both vectors are sorted
  # makes it about 40x faster than setdiff
  # the cost of verifying that the arrays
  @assert issorted(array)
  @assert issorted(to_delete)
  result = Int[]
  deletion_index = 1
  for i in array
    # iterate to the next valid index, value >= to i
    while (to_delete[deletion_index] < i) && (deletion_index < length(to_delete))
      deletion_index += 1
    end
    if i != to_delete[deletion_index]
      push!(result, i)
    end
  end
  result
end


function non_dominated_sort(double_population::Population,
                            comparison_operator = non_dominated_compare)
  # sort population into m nondominating fronts (best to worst)
  # until at least half the original number of individuals is put in a front

  # get number of individuals to keep
  population_size = length(population.individuals)
  cutoff = population_size / 2

  # get domination information
  # (individual_index, domination_count, dominated_by)
  domination_information = (Int, Int, Vector{Int})[]
  for index = 1:population_size
    push!(domination_information, evaluate_against_others(population, index, comparison_operator))
  end

  fronts_to_indices = Vector{Int}[]

  # iteratively find undominated individuals and separate them from the rest
  # until there are at least half of the double population in them
  while length(domination_information) > cutoff
    current_front_indices = Int[]

    # (individual_index, domination_count, dominated_by)
    tmp_domination_information = (Int, Int, Vector{Int})[]

    for (index, domination_count, dominated_by) in domination_information
      if domination_count == 0
        # the individual is dominating, we add its index to front_indices
        push!(current_front_indices, index)
      else
        # the individual is dominated
        push!(tmp_domination_information, (index, domination_count, dominated_by))
      end
    end

    # push the current front to the result
    push!(fronts_to_indices, current_front_indices)

    # remove the indices of the current front from the dominated individuals
    for (index, domination_count, dominated_by) in tmp_domination_information
      #remove indices from the current front
      substracted = fast_delete(dominated_by, current_front_indices)
      #substract the difference of cardinality
      push!(domination_information, (index, length(substracted), substracted))
    end
  end

  fronts_to_indices
end


function calculate_crowding_distance(population::Population,
                                     front_indices::Vector{Int},
                                     front_index::Int)
  # crowding distance measures the proximity of a
  # solution to its immediate neighbors of the same front. it is used
  # to preserve diversity, later in the algorithm.

  # get the fitnesses from the individuals of the front
  fitnesses = map(ind->ind.fitness, population.individuals[front_indices])

  # calculate mapping {fitness => crowding_distance}
  fitness_to_crowding = Dict{Vector, (Int, FloatingPoint)}()
  for fitness in fitnesses
    fitness_to_crowding[fitness] = (front_index, 0.0)
  end

  # get how many fitnesses and objectives we have
  fitness_keys = collect(keys(fitness_to_crowding))
  fitness_length = length(fitness_keys[1])

  # sort in decreasing order the fitness vectors for each objective
  sorted_by_objective = Vector{Vector{Number}}[]
  objective_range = Number[]

  for i = 1:fitness_length
    sorted = sort(fitness_keys, by = x->x[i], rev = true)
    push!(objective_range, sorted[1][i] - sorted[end][i])
    push!(sorted_by_objective, sorted)
  end

  # assign infinite crowding distance to maximum and
  # minimum fitness of each objective
  map(x -> fitness_to_crowding[x[end]] = (front_index, Inf), sorted_by_objective)
  map(x -> fitness_to_crowding[x[1]]   = (front_index, Inf), sorted_by_objective)

  # assign crowding crowding_distances to the other
  # fitness vectors for each objectives
  for i = 1:fitness_length
    # edge case here! if range == 0, 0 / 0 will give NaN, we ignore the objective in such case
    # in DEAP, this is treated using
    # if crowd[-1][0][i] == crowd[0][0][i]:
    #        continue
    if objective_range[i] != 0
      for j = (2:(length(fitness_keys)-1))
        crowding_distance = fitness_to_crowding[sorted_by_objective[i][j]][2]
        crowding_distance += ((sorted_by_objective[i][j-1][i] - sorted_by_objective[i][j+1][i]) / objective_range[i])
        fitness_to_crowding[sorted_by_objective[i][j]] = (front_index, crowding_distance)
      end
    end
  end

  fitness_to_crowding
end


function last_front_selection(population::Population,
                            indices::Vector{Int},
                            to_select::Int)
  @assert 0 < to_select <= length(indices) "not enough individuals to select"

  # since individuals within the same front do not dominate each other, they are
  # selected based crowding distance (greater diversity is desired)

  # map {fitness => crowding distance}
  fitness_to_crowding = calculate_crowding_distance(population, lastFrontIndices, -1)

  # map {fitness => indices}
  fitness_to_index = Dict{Vector, Vector{Int}}()
  for index in indices
    fitness = population.individuals[index].fitness
    fitness_to_index[fitness] = push!(get(fitness_to_index, fitness, Int[]), index)
  end

  # sort fitness by decreasing crowding distance
  fitness_to_crowding = sort(collect(fitness_to_crowding),
                             by = x -> x[2],  # crowding distance is 2nd field
                             rev = true)

  # choose individuals by iterating through unique fitness list
  # in decreasing order of crowding distance
  chosen_indices = Int[]

  position = 1
  while length(chosen_indices) < to_select
    len = length(fitness_to_index[fitness_to_crowding[position]])

    if len > 1  # multiple individuals with same fitness
      sample = rand(1:len)
      index = fitness_to_index[fitness_to_crowding[position]][sample]
      push!(chosen_indices, index)
      # individuals can be picked only once
      deleteat!(fitness_to_index[fitness_to_crowding[position]], sample)
      j += 1

    else # single individual with this fitness
      index = fitness_to_index[fitness_to_crowding[position]][1]
      push!(chosen_indices, index)
      deleteat!(fitness_to_crowding, position)
    end

    # wrap around
    if position > length(fitness_to_crowding)
      position = 1
    end
  end

  #return the indices of the chosen individuals on the last front
  chosen_indices
end


function select_without_replacement{T}(vector::Vector{T}, k::Int)
  # take k elements from L without replacing
  result = T[]
  vector = deepcopy(vector)
  vector_length = length(vector)
  if k == vector_length
    return vector
  end

  for _ = 1:k
    index = rand(1:vector_length)
    push!(result, vector[index])
    deleteat!(vector, index)
    vector_length -= 1
  end

  result
end


function crowded_compare(first ::(Int, FloatingPoint),
                        second::(Int, FloatingPoint))
  # crowded comparison operator
  # (rank, crowding distance)
  # if rank is the same, tie break with crowding distance
  # if same distance choose randomly
  @assert valueA[2]>=0
  @assert valueA[2]>=0
  # A rank < B rank
  if valueA[1] < valueB[1]
    return 0
  # B rank < A rank
  elseif valueA[1] > valueB[1]
    return 1
  # A dist > B dist
  elseif valueA[2] > valueB[2]
    return 0
  # B dist > A dist
  elseif valueA[2] < valueB[2]
    return 1
  # A == B, choose either
  else
    return rand(0:1)
  end
end


function unique_fitness_tournament_selection(population::Population)
  # select across entire range of fitnesses to avoid
  # bias by reoccuring fitnesses

  population_size = length(population.individuals)

  # associate fitness to indices of individuals
  # map {fitness => indices}
  fitness_to_index = Dict{Vector, Vector{Int}}()
  for i = 1:population_size
    value = get(fitness_to_index, population.individuals[i].fitness, Int[])
    fitness_to_index[population.individuals[i].fitness] = push!(value, i)
  end
  fitnesses = collect(keys(fitness_to_index))

  # edge case : only one fitness, return the population as it was
  if length(fitness_to_index) == 1
    return population.individuals
  end

  # else we must select parents
  newParents = Individual[]

  while length(newParents) != population_size
    # we either pick all the fitnesses and select a random Individual from them
    # or select a subset of them. depends on how many new parents we still need to add
    k = min((2*(population_size - length(newParents))), length(fitness_to_index))

    # sample k fitnesses and get their (front, crowing) from population.distances
    candidateFitnesses = select_without_replacement(fitnesses, k)
    frontAndCrowding = map(x->population.distances[x], candidateFitnesses)

    # choose n fittest out of 2n
    # by comparing pairs of neighbors
    chosenFitnesses = Vector[]
    i = 1
    while i < k
      # crowded_compare returns an offset (0 if first solution is better, 1 otherwise)
      selectedIndex = i + crowded_compare(frontAndCrowding[i], frontAndCrowding[i+1])
      push!(chosenFitnesses, candidateFitnesses[selectedIndex])
      i += 2
    end

    #we now randomly choose an Individual from the indices associated with the chosen fitnesses
    for i in chosenFitnesses
      chosenIndex = fitness_to_index[i][rand(1:length(fitness_to_index[i]))]
      push!(newParents, population.individuals[chosenIndex])
    end

  end
  newParents
end


function generateOffsprings(childrenTemplates::Vector{Individual}, 
                            probabilityOfCrossover::FloatingPoint,
                            probabilityOfMutation::FloatingPoint,
                            evaluationFunction::Function,
                            alleles,
                            mutationOperator,
                            crossoverOperator)
  # final step of the generation, creates the next population
  # from the children templates
  # initialize
  childrenPopulation = Population()
  popSize = length(childrenTemplates)

  # deciding who is mutating and having crossovers
  willMutate   = map(x->x <= probabilityOfMutation,  rand(length(childrenTemplates)))
  willRecombine= map(x->x <= probabilityOfCrossover, rand(length(childrenTemplates)))

  evolutionaryEvents = collect(zip(willMutate, willRecombine))

  for i = 1:popSize
    # initialize new genes and a new fitness from childrenTemplates genes and fitness
    new_genes = deepcopy(childrenTemplates[i].genes)
    newFitness = deepcopy(childrenTemplates[i].fitness)
    modified = false

    if evolutionaryEvents[i][1] == true
      modified = true

      #recombination (crossover)
      # randomly choose second parent
      secondParentIndex = rand(1:(popSize-1))

      # leave a gap to not select same parent
      if secondParentIndex >= i
        secondParentIndex += 1
      end

      # combine two childrenTemplates genes (on which the fitness is based)
      new_genes = crossoverOperator(new_genes, childrenTemplates[secondParentIndex].genes)
    end

    if evolutionaryEvents[i][2] == true
      modified = true
      # mutation
      new_genes = mutationOperator(new_genes, alleles)
    end

    # if modified, re-evaluate
    if modified
      newFitness = evaluationFunction(new_genes)
    end

    # add newly created individuals to the children population
    push!(childrenPopulation.individuals, Individual(new_genes, newFitness))
  end

  return childrenPopulation
end


function addToHallOfFame(population::Population,
                         firstFrontIndices::Vector{Int},
                         HallOfFame::hallOfFame,
                         maxSize=400)
  # add the best individuals to the Hall of Fame population to save them for
  # further examination. we merge the first front of the actual population
  # with the rest of the hall of fame to then select the first front of it.

  # we know from previous calculation the indices of the best individuals
  firstFront = population.individuals[firstFrontIndices]
  # println("num in hall of fame $(length(HallOfFame.individuals))")
  # println("num external first front $(length(firstFront))")


  # we add add the best individuals to the Hall of Fame
  for i in firstFront
    push!(HallOfFame.individuals, i)
  end

  # elmiminate duplicates (since it is elitist, same individuals may reappear)
  HallOfFame.individuals = unique(HallOfFame.individuals)

  # find the first non dominated front, to select the best individuals of the new Hall of Fame

  # acquire the domination values
  values = (Int, Int, Array{Int,1})[]
  for i=1:length(HallOfFame.individuals)
    push!(values, evaluate_against_others(HallOfFame, i, non_dominated_compare))
  end

  # get first front individuals
  firstFront2 = filter(x->x[2]==0, values)

  # get indices
  firstFrontIndices2 = map(x->x[1], firstFront2)
  firstFrontIndividuals = HallOfFame.individuals[firstFrontIndices2]

  fitnesses = unique(map(x->x.fitness, firstFrontIndividuals))

  # unique genes
  selected = Individual[]
  allGenes = Set{Vector}()
  for i in firstFrontIndividuals
    if !(i.genes in allGenes)
      push!(allGenes, i.genes)
      push!(selected, i)
    end
  end

  HallOfFame.individuals = selected
end


#BEGIN main

function main(alleles::Vector,
              fitness_function::Function,
              PopulationSize::Int,
              iterations::Int,
              probabilityOfCrossover = 0.1,
              probabilityOfMutation = 0.05,
              crossoverOperator = uniformCrossover,
              mutationOperator = uniformMutate)
  @assert PopulationSize > 0
  @assert iterations > 0

  #progress bar stuff
  # p = Progress(iterations, 1, "Generating solutions", 50)

  # main loop of the NSGA-II algorithm
  # create hall of fame to save the best individuals
  HallOfFame = hallOfFame()

  # initialize with two randomly initialized populations
  kickstartingPopulation = initializePopulation(alleles, fitness_function, PopulationSize)
  previousPopulation = initializePopulation(alleles, fitness_function, PopulationSize)

  # merge two initial parents
  mergedPopulation = Population(vcat(kickstartingPopulation.individuals, previousPopulation.individuals))

  # |selection -> offsprings| -> |selection -> offsprings| -> ...
  for i = 1:iterations
    # sort the merged population into non dominated fronts
    fronts = nonDominatedSort(mergedPopulation)

    # add the best individuals to the hall of fame
    addToHallOfFame(mergedPopulation, fronts[1], HallOfFame)


    if length(fronts) == 1 || length(fronts[1]) >= PopulationSize
        calculate_crowding_distance(mergedPopulation, fronts[1], 1, true)
        selectedFromLastFront = last_front_selection(mergedPopulation,
                                                   fronts[1],
                                                   PopulationSize)
        # put the indices of the individuals in all
        # fronts that were selected as parents
        parentsIndices = selectedFromLastFront
    else
        # separate last front from rest, it is treated differently with
        # last_front_selection function
        indexOfLastFront = length(fronts)
        lastFront = fronts[indexOfLastFront]
        fronts = fronts[1: (indexOfLastFront - 1)]

        #calculate the crowding crowding_distances for all but the last front and 
        #update the mergedPopulation.distance
        #   #if we wish to update, the dict of computed crowding_distances is merged to the main one
        #   #in P.distances
        #   if update == true
        #     merge!(P.distances, fitness_to_crowding)
        #   end

        for j = 1:length(fronts)
            front_j = fronts[j]
            calculate_crowding_distance(mergedPopulation, front_j, j, true)
        end

        #calculate how many individuals are left to 
        #select (there's n-k in the previous fronts)
        k = PopulationSize - length(reduce(vcat, fronts))

        #find the indices of the k individuals we need from the last front
        selectedFromLastFront = last_front_selection(mergedPopulation,
                                                lastFront,
                                                k)

        #update the crowding distance on the last front
        calculate_crowding_distance(mergedPopulation, selectedFromLastFront, indexOfLastFront, true)

        #put the indices of the individuals in all
        #fronts that were selected as parents
        parentsIndices = vcat(reduce(vcat, fronts), selectedFromLastFront)
    end

    #--------------------------------------------------------------------

    # at this point, we have all we need to create the next Population:
    #   -indices of n individuals that were selected from the merged Population
    #   -crowding distance and front information (in actualPop.distance)

    parentPopulation = Population(mergedPopulation.individuals[parentsIndices],
                                  mergedPopulation.distances)


    #print the dict of crowding_distances
#     for dist in keys(parentPopulation.distances)
#       print("[")
#       print(dist)
#       print("]")
#       print(" : ")
#       print(parentPopulation.distances[dist])
#       println("")
#     end
    #we make a tournament selection to select children
    #the templates are actual parents
    childrenTemplates = unique_fitness_tournament_selection(parentPopulation)

    # apply genetic operators (recomination and mutation) to obtain next pop
    nextPopulation = generateOffsprings(childrenTemplates,
                                        probabilityOfCrossover,
                                        probabilityOfMutation,
                                        fitness_function,
                                        alleles,
                                        mutationOperator,
                                        crossoverOperator)
    # we now have a new Population, we must now
    # -create a new merged population
    # -assign this newly produce population as being the previous of the next loop
    mergedPopulation = Population(vcat(nextPopulation.individuals, previousPopulation.individuals))
    previousPopulation = nextPopulation

    next!(p)
  end

  return [HallOfFame, previousPopulation]
end

